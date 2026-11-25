# chainsvc (.NET). Derleme bağlamı: apps/chainsvc (ortak proto/ için). Bkz. lib/app.sh app_build
FROM mcr.microsoft.com/dotnet/sdk:10.0.404 AS build
WORKDIR /src
COPY proto/ proto/
COPY dotnet/ChainSvc.csproj dotnet/
RUN dotnet restore dotnet/ChainSvc.csproj
COPY dotnet/ dotnet/
RUN dotnet publish dotnet/ChainSvc.csproj -c Release -o /app --no-restore

# Ubuntu chiseled: kabuk ve paket yöneticisi yok, root olmayan kullanıcı (UID 1654)
FROM mcr.microsoft.com/dotnet/aspnet:10.0.15-noble-chiseled
LABEL smlab.lang="dotnet" smlab.runtime=".NET 10.0.15 (ASP.NET Core Kestrel, Grpc.AspNetCore 2.85.0)"
WORKDIR /app
COPY --from=build /app .
# Dinleme adresi LISTEN_ADDR ile koddan verilir; imajın varsayılan 8080 portu kapatılır
ENV ASPNETCORE_HTTP_PORTS=
EXPOSE 9090
ENTRYPOINT ["dotnet", "chainsvc.dll"]
