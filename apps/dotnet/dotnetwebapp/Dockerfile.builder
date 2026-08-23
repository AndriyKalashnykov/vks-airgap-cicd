# syntax=docker/dockerfile:1.26
# Builder image for AIR-GAPPED CI: bakes this app's NuGet cache so the in-cluster build needs NO
# nuget.org. Build on the INTERNET-connected jump box, push to Harbor.
#
# .NET IS THE THIN CASE: the app declares no PackageReference because ASP.NET Core's shared
# framework already carries Kestrel and Razor. `dotnet restore` still resolves the framework
# reference packs, and doing it HERE is what lets the in-cluster build run `--no-restore`.
#
# Rebuild whenever the .csproj changes. scripts/14-builder-build.sh resolves the base image and the
# ARG NAME below PER APP via lib/apps.sh.
ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0-alpine
# DOTNET_SDK_IMAGE default is explicitly tagged; DL3006 can't see through the ARG.
# hadolint ignore=DL3006
FROM ${DOTNET_SDK_IMAGE}

WORKDIR /build
# The project file FIRST so the restore layer caches independently of the source.
COPY dotnetwebapp.csproj ./
RUN dotnet restore

COPY . .
# The image's value is its warm ~/.nuget/packages, inherited by the app Dockerfile.
