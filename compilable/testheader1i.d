// EXTRA_SOURCES: extra-files/header1.d
// REQUIRED_ARGS: -o- -H -Hd${RESULTS_DIR}/compilable -inline
// PERMUTE_ARGS: -d -dw
// POST_SCRIPT: compilable/extra-files/header-postscript.sh header1i

void main() {}