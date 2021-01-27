#/bin/bash
mkdir release
cd release
while read line
do
    echo "File:${line}"
    ./cowtransfer-uploader -p 8 --password=aaabbbcc321 ${line}
done < ../files.txt
