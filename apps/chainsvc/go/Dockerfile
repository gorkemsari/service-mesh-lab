# chainsvc (Go). Derleme bağlamı: apps/chainsvc (ortak proto/ için). Bkz. lib/app.sh app_build
FROM golang:1.26.11-alpine AS build
WORKDIR /src
COPY go/go.mod go/go.sum ./
RUN go mod download
COPY go/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /chainsvc .

FROM scratch
LABEL smlab.lang="go" smlab.runtime="Go 1.26.11 (net/http, grpc-go 1.75.0)"
COPY --from=build /chainsvc /chainsvc
USER 65532:65532
EXPOSE 9090
ENTRYPOINT ["/chainsvc"]
