#!/usr/bin/env bash
# chain.proto -> go/chainpb/*.pb.go (Docker içinde protoc; yerel kurulum gerekmez).
# proto değiştiğinde çalıştırılır; üretilen kod repoda tutulur (Go derlemesi protoc'a ihtiyaç duymaz).
# .NET kodu derleme sırasında Grpc.Tools ile üretildiği için ayrı adım gerekmez.
set -euo pipefail
cd "$(dirname "$0")/.."
docker run --rm -e UIDGID="$(id -u):$(id -g)" -v "$PWD:/src" -w /src golang:1.26.11-alpine sh -euc '
    apk add -q --no-cache protobuf protobuf-dev
    go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.6
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
    protoc -I proto --go_out=go --go_opt=module=smlab/chainsvc \
      --go-grpc_out=go --go-grpc_opt=module=smlab/chainsvc proto/chain.proto
    chown -R "$UIDGID" go/chainpb'
echo "üretildi: go/chainpb/"
