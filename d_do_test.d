#!/usr/bin/env rdmd
module d_do_test;

version(LDC) version(CRuntime_Microsoft) version = LDC_MSVC;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.process;
import std.random;
import std.regex;
import std.stdio;
import std.string;
import core.sys.posix.sys.wait;

void usage()
{
    write("d_do_test <input_dir> <test_name> <test_extension>\n"
          ~ "\n"
          ~ "   Note: this program is normally called through the Makefile, it"
          ~ "         is not meant to be called directly by the user.\n"
          ~ "\n"
          ~ "   input_dir: one of: compilable, fail_compilation, runnable\n"
          ~ "   test_name: basename of test case to run\n"
          ~ "   test_extension: one of: d, html, or sh\n"
          ~ "\n"
          ~ "   example: d_do_test runnable pi d\n"
          ~ "\n"
          ~ "   relevant environment variables:\n"
          ~ "      ARGS:          set to execute all combinations of\n"
          ~ "      REQUIRED_ARGS: arguments always passed to the compiler\n"
          ~ "      DMD:           compiler to use, ex: ../src/dmd (required)\n"
          ~ "      CC:            C++ compiler to use, ex: dmc, g++\n"
          ~ "      OS:            win32, win64, linux, freebsd, osx, netbsd\n"
          ~ "      RESULTS_DIR:   base directory for test results\n"
          ~ "      MODEL:         32 or 64 (required)\n"
          ~ "   windows vs non-windows portability env vars:\n"
          ~ "      DSEP:          \\\\ or /\n"
          ~ "      SEP:           \\ or / (required)\n"
          ~ "      OBJ:          .obj or .o (required)\n"
          ~ "      EXE:          .exe or <null> (required)\n");
}

enum TestMode
{
    COMPILE,
    FAIL_COMPILE,
    RUN
}

struct TestArgs
{
    TestMode mode;

    bool     compileSeparately;
    string   executeArgs;
    string[] sources;
    string[] cppSources;
    string[] objcSources;
    string   permuteArgs;
    string   compileOutput;
    string   gdbScript;
    string   gdbMatch;
    string   postScript;
    string   requiredArgs;
    string   requiredArgsForLink;
    // reason for disabling the test (if empty, the test is not disabled)
    string[] disabledPlatforms;
    bool     disabled;
}

struct EnvData
{
    string all_args;
    string dmd;
    string results_dir;
    string sep;
    string dsep;
    string obj;
    string exe;
    string os;
    string compiler;
    string ccompiler;
    string model;
    string required_args;
    bool dobjc;
    bool coverage_build;
    bool noArchVariant;
}

bool findTestParameter(const ref EnvData envData, string file, string token, ref string result)
{
    auto tokenStart = std.string.indexOf(file, token);
    if (tokenStart == -1) return false;

    auto lineEndR = std.string.indexOf(file[tokenStart .. $], "\r");
    auto lineEndN = std.string.indexOf(file[tokenStart .. $], "\n");
    auto lineEnd  = lineEndR == -1 ?
        (lineEndN == -1 ? file.length : lineEndN) :
        (lineEndN == -1 ? lineEndR    : min(lineEndR, lineEndN));

    //writeln("found ", token, " in line: ", file.length, ", ", tokenStart, ", ", tokenStart+lineEnd);
    //writeln("found ", token, " in line: '", file[tokenStart .. tokenStart+lineEnd], "'");

    result = strip(file[tokenStart+token.length .. tokenStart+lineEnd]);
    // filter by OS specific setting (os1 os2 ...)
    if (result.length > 0 && result[0] == '(')
    {
        auto close = std.string.indexOf(result, ")");
        if (close >= 0)
        {
            string[] oss = split(result[1 .. close], " ");
            if (oss.canFind(envData.os))
                result = result[close + 1..$];
            else
                result = null;
        }
    }
    // skips the :, if present
    if (result.length > 0 && result[0] == ':')
        result = strip(result[1 .. $]);

    //writeln("arg: '", result, "'");

    string result2;
    if (findTestParameter(envData, file[tokenStart+lineEnd..$], token, result2))
        result ~= " " ~ result2;

    return true;
}

bool findOutputParameter(string file, string token, out string result, string sep)
{
    bool found = false;

    while (true)
    {
        auto istart = std.string.indexOf(file, token);
        if (istart == -1)
            break;
        found = true;

        // skips the :, if present
        if (file[istart] == ':') ++istart;

        enum embed_sep = "---";
        auto n = std.string.indexOf(file[istart .. $], embed_sep);

        enforce(n != -1, "invalid "~token~" format");
        istart += n + embed_sep.length;
        while (file[istart] == '-') ++istart;
        if (file[istart] == '\r') ++istart;
        if (file[istart] == '\n') ++istart;

        auto iend = std.string.indexOf(file[istart .. $], embed_sep);
        enforce(iend != -1, "invalid TEST_OUTPUT format");
        iend += istart;

        result ~= file[istart .. iend];

        while (file[iend] == '-') ++iend;
        file = file[iend .. $];
    }

    if (found)
    {
        result = std.string.strip(result);
        result = result.unifyNewLine().unifyDirSep(sep);
        result = result ? result : ""; // keep non-null
    }
    return found;
}

void replaceResultsDir(ref string arguments, const ref EnvData envData)
{
    // Bash would expand this automatically on Posix, but we need to manually
    // perform the replacement for Windows compatibility.
    arguments = replace(arguments, "${RESULTS_DIR}", envData.results_dir);
}

bool gatherTestParameters(ref TestArgs testArgs, string input_dir, string input_file, const ref EnvData envData)
{
    string file = cast(string)std.file.read(input_file);

    findTestParameter(envData, file, "REQUIRED_ARGS", testArgs.requiredArgs);
    if (envData.required_args.length)
    {
        if (testArgs.requiredArgs.length)
            testArgs.requiredArgs ~= " " ~ envData.required_args;
        else
            testArgs.requiredArgs = envData.required_args;
    }
    replaceResultsDir(testArgs.requiredArgs, envData);

    if (! findTestParameter(envData, file, "PERMUTE_ARGS", testArgs.permuteArgs))
    {
        if (testArgs.mode == TestMode.RUN)
            testArgs.permuteArgs = envData.all_args;

        string unittestJunk;
        if(!findTestParameter(envData, file, "unittest", unittestJunk))
            testArgs.permuteArgs = replace(testArgs.permuteArgs, "-unittest", "");
    }
    replaceResultsDir(testArgs.permuteArgs, envData);

    // remove permute args enforced as required anyway
    if (testArgs.requiredArgs.length && testArgs.permuteArgs.length)
    {
        const required = split(testArgs.requiredArgs);
        const newPermuteArgs = split(testArgs.permuteArgs)
            .filter!(a => !required.canFind(a))
            .join(" ");
        testArgs.permuteArgs = newPermuteArgs;
    }

    // win(32|64) doesn't support pic
    if (envData.os == "win32" || envData.os == "win64")
    {
        auto index = std.string.indexOf(testArgs.permuteArgs, "-fPIC");
        if (index != -1)
            testArgs.permuteArgs = testArgs.permuteArgs[0 .. index] ~ testArgs.permuteArgs[index+5 .. $];
    }

    // clean up extra spaces
    testArgs.permuteArgs = strip(replace(testArgs.permuteArgs, "  ", " "));

    findTestParameter(envData, file, "EXECUTE_ARGS", testArgs.executeArgs);
    replaceResultsDir(testArgs.executeArgs, envData);

    string extraSourcesStr;
    findTestParameter(envData, file, "EXTRA_SOURCES", extraSourcesStr);
    testArgs.sources = [input_file];
    // prepend input_dir to each extra source file
    foreach(s; split(extraSourcesStr))
        testArgs.sources ~= input_dir ~ "/" ~ s;

    string extraCppSourcesStr;
    findTestParameter(envData, file, "EXTRA_CPP_SOURCES", extraCppSourcesStr);
    testArgs.cppSources = [];
    // prepend input_dir to each extra source file
    foreach(s; split(extraCppSourcesStr))
        testArgs.cppSources ~= s;

    string extraObjcSourcesStr;
    auto objc = findTestParameter(envData, file, "EXTRA_OBJC_SOURCES", extraObjcSourcesStr);

    if (objc && !envData.dobjc)
        return false;

    testArgs.objcSources = [];
    // prepend input_dir to each extra source file
    foreach(s; split(extraObjcSourcesStr))
        testArgs.objcSources ~= s;

    // swap / with $SEP
    if (envData.sep && envData.sep != "/")
        foreach (ref s; testArgs.sources)
            s = replace(s, "/", to!string(envData.sep));
    //writeln ("sources: ", testArgs.sources);

    // COMPILE_SEPARATELY can take optional compiler switches when link .o files
    testArgs.compileSeparately = findTestParameter(envData, file, "COMPILE_SEPARATELY", testArgs.requiredArgsForLink);

    string disabledPlatformsStr;
    findTestParameter(envData, file, "DISABLED", disabledPlatformsStr);
    testArgs.disabledPlatforms = split(disabledPlatformsStr);

    findOutputParameter(file, "TEST_OUTPUT", testArgs.compileOutput, envData.sep);

    findOutputParameter(file, "GDB_SCRIPT", testArgs.gdbScript, envData.sep);
    findTestParameter(envData, file, "GDB_MATCH", testArgs.gdbMatch);

    if (findTestParameter(envData, file, "POST_SCRIPT", testArgs.postScript))
        testArgs.postScript = replace(testArgs.postScript, "/", to!string(envData.sep));

    return true;
}

string[] combinations(string argstr)
{
    string[] results;
    string[] args = split(argstr);
    long combinations = 1 << args.length;
    for (size_t i = 0; i < combinations; i++)
    {
        string r;
        bool printed = false;

        for (size_t j = 0; j < args.length; j++)
        {
            if (i & 1 << j)
            {
                if (printed)
                    r ~= " ";
                r ~= args[j];
                printed = true;
            }
        }

        results ~= r;
    }

    return results;
}

string genTempFilename(string result_path)
{
    auto a = appender!string();
    a.put(result_path);
    foreach (ref e; 0 .. 8)
    {
        formattedWrite(a, "%x", rndGen.front);
        rndGen.popFront();
    }

    return a.data;
}

int system(string command)
{
    static import core.stdc.stdlib;
    if (!command) return core.stdc.stdlib.system(null);
    const commandz = toStringz(command);
    auto status = core.stdc.stdlib.system(commandz);
    if (status == -1) return status;
    version (Windows) status <<= 8;
    return status;
}

version(Windows)
{
    extern (D) bool WIFEXITED( int status )    { return ( status & 0x7F ) == 0; }
    extern (D) int  WEXITSTATUS( int status )  { return ( status & 0xFF00 ) >> 8; }
    extern (D) int  WTERMSIG( int status )     { return status & 0x7F; }
    extern (D) bool WIFSIGNALED( int status )
    {
        return ( cast(byte) ( ( status & 0x7F ) + 1 ) >> 1 ) > 0;
    }
}

void removeIfExists(in char[] filename)
{
    if (std.file.exists(filename))
        std.file.remove(filename);
}

string execute(ref File f, string command, bool expectpass, string result_path)
{
    auto filename = genTempFilename(result_path);
    scope(exit) removeIfExists(filename);

    auto rc = system(command ~ " > " ~ filename ~ " 2>&1");

    string output = readText(filename);
    f.writeln(command);
    f.write(output);

    if (WIFSIGNALED(rc))
    {
        auto value = WTERMSIG(rc);
        enforce(0 == value, "caught signal: " ~ to!string(value));
    }
    else if (WIFEXITED(rc))
    {
        auto value = WEXITSTATUS(rc);
        if (expectpass)
            enforce(0 == value, "expected rc == 0, exited with rc == " ~ to!string(value));
        else
            enforce(1 == value, "expected rc == 1, but exited with rc == " ~ to!string(value));
    }

    return output;
}

string unifyNewLine(string str)
{
    return std.regex.replace(str, regex(`\r\n|\r|\n`, "g"), "\n");
}

string unifyDirSep(string str, string sep)
{
    return std.regex.replace(str, regex(`(?<=[-\w][-\w]*)/(?=[-\w][-\w/]*\.di?\b)`, "g"), sep);
}
unittest
{
    assert(`fail_compilation/test.d(1) Error: dummy error message for 'test'`.unifyDirSep(`\`)
        == `fail_compilation\test.d(1) Error: dummy error message for 'test'`);
    assert(`fail_compilation/test.d(1) Error: at fail_compilation/test.d(2)`.unifyDirSep(`\`)
        == `fail_compilation\test.d(1) Error: at fail_compilation\test.d(2)`);

    assert(`fail_compilation/test.d(1) Error: at fail_compilation/imports/test.d(2)`.unifyDirSep(`\`)
        == `fail_compilation\test.d(1) Error: at fail_compilation\imports\test.d(2)`);
    assert(`fail_compilation/diag.d(2): Error: fail_compilation/imports/fail.d must be imported`.unifyDirSep(`\`)
        == `fail_compilation\diag.d(2): Error: fail_compilation\imports\fail.d must be imported`);
}

bool collectExtraSources (in string input_dir, in string output_dir, in string[] extraSources, ref string[] sources, bool msc, in EnvData envData, in string compiler)
{
    foreach (cur; extraSources)
    {
        auto curSrc = input_dir ~ envData.sep ~"extra-files" ~ envData.sep ~ cur;
        auto curObj = output_dir ~ envData.sep ~ cur ~ envData.obj;
        string command = compiler;
        if (envData.compiler == "dmd")
        {
            if (msc)
            {
                command ~= ` /c /nologo `~curSrc~` /Fo`~curObj;
            }
            else if (envData.os == "win32")
            {
                command ~= " -c "~curSrc~" -o"~curObj;
            }
            else
            {
                if (!envData.noArchVariant)
                    command ~= " -m"~envData.model;
                command ~= " -c "~curSrc~" -o "~curObj;
            }
        }
        else
        {
            if (!envData.noArchVariant)
                command ~= " -m"~envData.model;
            command ~= " -c "~curSrc~" -o "~curObj;
        }

        auto rc = system(command);
        if(rc)
        {
            writeln("failed to execute '"~command~"'");
            return false;
        }
        sources ~= curObj;
    }

    return true;
}

// compare output string to reference string, but ignore places
// marked by $n$ that contain compiler generated unique numbers
bool compareOutput(string output, string refoutput)
{
    import std.ascii : digits;
    import std.utf : byCodeUnit;
    for ( ; ; )
    {
        auto pos = refoutput.indexOf("$n$");
        if (pos < 0)
            return refoutput == output;
        if (output.length < pos)
            return false;
        if (refoutput[0..pos] != output[0..pos])
            return false;
        refoutput = refoutput[pos + 3 ..$];
        output = output[pos..$];
        auto p = output.byCodeUnit.countUntil!(e => !digits.canFind(e));
        output = output[p..$];
    }
}

string envGetRequired(in char[] name)
{
    auto value = environment.get(name);
    if(value is null)
    {
        writefln("Error: missing environment variable '%s', was this called this through the Makefile?",
            name);
        throw new SilentQuit();
    }
    return value;
}

class SilentQuit : Exception { this() { super(null); } }

int main(string[] args)
{
    try { return tryMain(args); }
    catch(SilentQuit) { return 1; }
}

int tryMain(string[] args)
{
    if (args.length != 4)
    {
        if (args.length == 2 && args[1] == "-unittest")
            return 0;
        usage();
        return 1;
    }

    string input_dir      = args[1];
    string test_name      = args[2];
    string test_extension = args[3];

    EnvData envData;
    envData.all_args      = environment.get("ARGS");
    envData.results_dir   = environment.get("RESULTS_DIR");
    envData.sep           = envGetRequired ("SEP");
    envData.dsep          = environment.get("DSEP");
    envData.obj           = envGetRequired ("OBJ");
    envData.exe           = envGetRequired ("EXE");
    envData.os            = environment.get("OS");
    envData.dmd           = replace(envGetRequired("DMD"), "/", envData.sep);
    envData.compiler      = "dmd"; //should be replaced for other compilers
    envData.ccompiler     = environment.get("CC");
    envData.model         = envGetRequired("MODEL");
    envData.required_args = environment.get("REQUIRED_ARGS");
    envData.dobjc         = environment.get("D_OBJC") == "1";
    envData.coverage_build   = environment.get("DMD_TEST_COVERAGE") == "1";
    envData.noArchVariant = environment.get("NO_ARCH_VARIANT") == "1";

    string result_path    = envData.results_dir ~ envData.sep;
    version (Windows)
        result_path = result_path.replace("/", `\`);
    string input_file     = input_dir ~ envData.sep ~ test_name ~ "." ~ test_extension;
    string output_dir     = result_path ~ input_dir;
    string output_file    = result_path ~ input_dir ~ envData.sep ~ test_name ~ "." ~ test_extension ~ ".out";
    string test_app_dmd_base = output_dir ~ envData.sep ~ test_name ~ "_";

    TestArgs testArgs;

    switch (input_dir)
    {
        case "compilable":              testArgs.mode = TestMode.COMPILE;      break;
        case "fail_compilation":        testArgs.mode = TestMode.FAIL_COMPILE; break;
        case "runnable":                testArgs.mode = TestMode.RUN;          break;
        default:
            writeln("input_dir must be one of 'compilable', 'fail_compilation', or 'runnable'");
            return 1;
    }

    // running & linking costs time - for coverage builds we can save this
    if (envData.coverage_build && testArgs.mode == TestMode.RUN)
        testArgs.mode = TestMode.COMPILE;

    if (envData.ccompiler.empty)
    {
        switch (envData.os)
        {
          version(LDC_MSVC)
          {
            case "win32": envData.ccompiler = "cl.exe"; break;
            case "win64": envData.ccompiler = "cl.exe"; break;
          }
          else
          {
            case "win32": envData.ccompiler = "dmc"; break;
            case "win64": envData.ccompiler = `\"Program Files (x86)"\"Microsoft Visual Studio 10.0"\VC\bin\amd64\cl.exe`; break;
          }
            default:      envData.ccompiler = "g++"; break;
        }
    }
    bool msc = envData.ccompiler.toLower.endsWith("cl.exe");

    if (!gatherTestParameters(testArgs, input_dir, input_file, envData))
        return 0;

    //prepare cpp extra sources
    if (testArgs.cppSources.length)
    {
        switch (envData.compiler)
        {
            case "dmd":
                if(envData.os != "win32" && envData.os != "win64")
                   testArgs.requiredArgs ~= " -L-lstdc++";
                break;
            case "ldc":
                testArgs.requiredArgs ~= " -L-lstdc++";
                break;
            case "gdc":
                testArgs.requiredArgs ~= "-Xlinker -lstdc++";
                break;
            default:
                writeln("unknown compiler: "~envData.compiler);
                return 1;
        }
        if (!collectExtraSources(input_dir, output_dir, testArgs.cppSources, testArgs.sources, msc, envData, envData.ccompiler))
            return 1;
    }
    //prepare objc extra sources
    if (!collectExtraSources(input_dir, output_dir, testArgs.objcSources, testArgs.sources, msc, envData, "clang"))
        return 1;

    writef(" ... %-30s %s%s(%s)",
            input_file,
            testArgs.requiredArgs,
            (!testArgs.requiredArgs.empty ? " " : ""),
            testArgs.permuteArgs);

    if (testArgs.disabledPlatforms.canFind(envData.os, envData.os ~ envData.model))
    {
        testArgs.disabled = true;
        writefln("!!! [DISABLED on %s]", envData.os);
    }
    else
        write("\n");

    removeIfExists(output_file);

    auto f = File(output_file, "a");

    foreach (i, c; combinations(testArgs.permuteArgs))
    {
        string test_app_dmd = test_app_dmd_base ~ to!string(i) ~ envData.exe;

        try
        {
            string[] toCleanup;

            auto thisRunName = genTempFilename(result_path);
            auto fThisRun = File(thisRunName, "w");
            scope(exit)
            {
                fThisRun.close();
                f.write(readText(thisRunName));
                f.writeln();
                removeIfExists(thisRunName);
            }

            // can override -verrors by using REQUIRED_ARGS
            auto reqArgs =
                (testArgs.mode == TestMode.FAIL_COMPILE ? "-verrors=0 " : null) ~
                testArgs.requiredArgs;

            // https://issues.dlang.org/show_bug.cgi?id=10664: exceptions don't work reliably with COMDAT folding
            // it also slows down some tests drastically, e.g. runnable/test17338.d
            if (msc)
                reqArgs ~= " -L/OPT:NOICF";

            string compile_output;
            if (!testArgs.compileSeparately)
            {
                string objfilename = test_name ~ "_" ~ to!string(i) ~ envData.obj;
                string objfilepath = output_dir ~ envData.sep ~ objfilename;
                toCleanup ~= objfilepath;

                string of = testArgs.mode == TestMode.RUN
                    ? test_app_dmd
                    /**
                     * HACK: Some tests use -lib. For a relative output_dir, it is required to
                     * pass -of=<name_without_path>.o[bj] for the static library (!) to end up
                     * in the output_dir specified via -od, as a relative -of path for static
                     * libs (and static libs only!) is treated as relative to the -od dir.
                     */
                    : (reqArgs.canFind("-lib ") || reqArgs.endsWith("-lib")
                        ? objfilename : objfilepath);

                string command = format("%s -conf= -m%s -I%s %s %s -od%s -of%s %s%s", envData.dmd, envData.model, input_dir,
                        reqArgs, c, output_dir, of,
                        (testArgs.mode == TestMode.RUN ? "" : "-c "),
                        join(testArgs.sources, " "));
                version (LDC) {} else version(Windows) command ~= " -map nul.map";

                compile_output = execute(fThisRun, command, testArgs.mode != TestMode.FAIL_COMPILE, result_path);
            }
            else
            {
                foreach (filename; testArgs.sources)
                {
                    string newo= result_path ~ replace(replace(filename, ".d", envData.obj), envData.sep~"imports"~envData.sep, envData.sep);
                    toCleanup ~= newo;

                    string command = format("%s -conf= -m%s -I%s %s %s -od%s -c %s", envData.dmd, envData.model, input_dir,
                        reqArgs, c, output_dir, filename);
                    compile_output ~= execute(fThisRun, command, testArgs.mode != TestMode.FAIL_COMPILE, result_path);
                }

                if (testArgs.mode == TestMode.RUN)
                {
                    // link .o's into an executable
                    string command = format("%s -conf= -m%s %s %s -od%s -of%s %s", envData.dmd, envData.model, envData.required_args,
                            testArgs.requiredArgsForLink, output_dir, test_app_dmd, join(toCleanup, " "));
                    version (LDC) {} else version(Windows) command ~= " -map nul.map";

                    execute(fThisRun, command, true, result_path);
                }
            }

            compile_output = std.regex.replace(compile_output, regex(`^DMD v2\.[0-9]+.* DEBUG$`, "m"), "");
            compile_output = std.string.strip(compile_output);
            compile_output = compile_output.unifyNewLine();

            auto m = std.regex.match(compile_output, `Internal error: .*$`);
            enforce(!m, m.hit);

            if (testArgs.compileOutput !is null)
            {
                enforce(compareOutput(compile_output, testArgs.compileOutput),
                        "\nexpected:\n----\n"~testArgs.compileOutput~"\n----\nactual:\n----\n"~compile_output~"\n----\n");
            }

            if (testArgs.mode == TestMode.RUN)
            {
                toCleanup ~= test_app_dmd;
                version(Windows)
                    if (msc)
                    {
                        toCleanup ~= test_app_dmd_base ~ to!string(i) ~ ".ilk";
                        toCleanup ~= test_app_dmd_base ~ to!string(i) ~ ".pdb";
                    }

                if (testArgs.gdbScript is null)
                {
                    string command = test_app_dmd;
                    if (testArgs.executeArgs) command ~= " " ~ testArgs.executeArgs;

                    execute(fThisRun, command, true, result_path);
                }
                else version (linux)
                {
                    auto script = test_app_dmd_base ~ to!string(i) ~ ".gdb";
                    toCleanup ~= script;
                    with (File(script, "w"))
                    {
                        writeln("set disable-randomization off");
                        write(testArgs.gdbScript);
                    }
                    string command = "gdb "~test_app_dmd~" --batch -x "~script;
                    auto gdb_output = execute(fThisRun, command, true, result_path);
                    if (testArgs.gdbMatch !is null)
                    {
                        enforce(match(gdb_output, regex(testArgs.gdbMatch)),
                                "\nGDB regex: '"~testArgs.gdbMatch~"' didn't match output:\n----\n"~gdb_output~"\n----\n");
                    }
                }
            }

            fThisRun.close();

            if (testArgs.postScript && !envData.coverage_build)
            {
                f.write("Executing post-test script: ");
                string prefix = "";
                version (Windows) prefix = "bash ";
                execute(f, prefix ~ testArgs.postScript ~ " " ~ thisRunName, true, result_path);
            }

            foreach (file; toCleanup) collectException(std.file.remove(file));
        }
        catch(Exception e)
        {
            // it failed but it was disabled, exit as if it was successful
            if (testArgs.disabled)
                return 0;

            f.writeln();
            f.writeln("==============================");
            f.writeln("Test failed: ", e.msg);
            f.close();

            writeln("Test failed.  The logged output:");
            writeln(cast(string)std.file.read(output_file));
            std.file.remove(output_file);
            return 1;
        }
    }

    // it was disabled but it passed! print an informational message
    if (testArgs.disabled)
        writefln(" !!! %-30s DISABLED but PASSES!", input_file);

    return 0;
}
