FROM alpine:3.13
RUN apk update && apk add --no-cache rsync
ENTRYPOINT exec /bin/ash -c "trap : TERM INT; sleep infinity & wait"
