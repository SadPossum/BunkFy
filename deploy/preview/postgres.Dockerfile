FROM postgres:17.11-alpine3.23@sha256:05aa77262db9277fde6374bb2f901c9604b8a9373029e1a7993440c6aae48736
ADD --checksum=sha256:0469e5c1ebc5f9d07c260f403b8bc7faaf65f8672a1f113fda9d34ab5b6701a0 https://dl-cdn.alpinelinux.org/alpine/v3.23/main/x86_64/libxslt-1.1.43-r4.apk /tmp/libxslt.apk
RUN apk add --no-cache --no-network --repositories-file /dev/null /tmp/libxslt.apk && rm /tmp/libxslt.apk /var/log/apk.log
USER 70:70
