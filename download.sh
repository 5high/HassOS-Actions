#/bin/bash
mkdir release
cd release
while read line
do
    echo "File:${line}"
    ../cowtransfer-uploader -p 8 --password=${{ secrets.COWPASS }} ${line}
done < ../files.txt
