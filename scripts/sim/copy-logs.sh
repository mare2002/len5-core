# Copy generated waves to common directory
# Usage: copy-waves.sh wave_file [wave_file] ...

ROOT_DIR=$(git rev-parse --show-toplevel)
COMMON_DIR="${BUILD_DIR:-$ROOT_DIR/build}/sim-common"
mkdir -p "$COMMON_DIR"
for file in "$@"; do
    [ ! -f $file ] && continue
    FILE_EXT="${file##*.}"
    rm -f "$COMMON_DIR"/waves.$FILE_EXT
    ln -sr $file "$COMMON_DIR"/waves.$FILE_EXT
done

# Additionally copy separate wave files, if any
FILE_LIST=$(find $(dirname $1) -name "*.vcd")
for file in $FILE_LIST; do
    rm -f "$COMMON_DIR"/$(basename $file)
    ln -sr $file "$COMMON_DIR"/
done

# Copy execution trace log, if any
TRACE_FILE="$(dirname $1)/sim-trace.log"
if [ -f $TRACE_FILE ]; then
    rm -f "$COMMON_DIR"/sim-trace.log
    ln -sr $TRACE_FILE "$COMMON_DIR"/
fi

exit 0
