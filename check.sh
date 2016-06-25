#!/bin/bash
clear
export DEBUG=1
make -f posix.mak -j9  || { echo 'compilation failed' ; exit 1; }

for file in `ls test/mangling/*.d`; do
    ./src/dmd -o- -c -main $file >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo $file OK
    else
        echo "######################################################"
        echo ">>>>>" $file "<<<<<"
        cat $file
        echo "######################################################"
        ./src/dmd -o- -c -main $file
    fi
done
