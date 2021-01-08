#!/bin/bash
PORT=9999
FILE=/home/core/bootstrap.ign
MIME_TYPE=$(mimetype "$FILE")
SIZE_BYTES=$(du -b "$FILE" | cut -f1)
FILE_NAME=$(basename "$FILE")

HEADER="\
HTTP/1.1 200 OK
Content-Type: $MIME_TYPE
Content-Disposition: attachment; filename=$FILE_NAME
Content-Length: $SIZE_BYTES

"
while true; do
socat -d -d - tcp-l:"$PORT",reuseaddr < <(printf "$HEADER"; cat "$FILE")
done