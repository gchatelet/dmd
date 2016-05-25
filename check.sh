#!/bin/bash
set -e
clear
make -f posix.mak -j9
for file in `find test/mangling -name '*.d' -type f`; do
    echo "######################################################"
    echo ">>>>>" $file "<<<<<"
    ./src/dmd -main $file
done
