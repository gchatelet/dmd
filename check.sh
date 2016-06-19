#!/bin/bash
clear
make -f posix.mak -j9  || { echo 'compilation failed' ; exit 1; }
for file in `ls test/mangling/*.d`; do
    echo "######################################################"
    echo ">>>>>" $file "<<<<<"
    cat $file
    echo "######################################################"
    ./src/dmd -c -main $file
done
