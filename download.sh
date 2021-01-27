#/bin/bash
while read line
do
    echo "File:${line}"
done < files.txt
