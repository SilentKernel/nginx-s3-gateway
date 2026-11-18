# Driven by build.sh, which exports versions.env and the resolved version. Two stages:
#   oss           Dockerfile.oss on ${NGINX_BASE}, our nginx-docker image pinned by digest (njs, S3
#                 gateway config, then the day's Debian updates)
#   unprivileged  Dockerfile.unprivileged on top of it (port 8080, user nginx): what we publish
# The "nginx-s3-gateway" image Dockerfile.unprivileged starts FROM is the oss target itself, never a
# local tag: another build on the same Docker engine cannot swap it.

# The nginx image to build on (scripts/resolve-base.sh) and the nginx it carries (labels, tags).
variable "NGINX_BASE" {}
variable "NGINX_VERSION" {}
variable "MIN_NGINX_VERSION" {}
variable "DEBIAN" {}
variable "PLATFORM" {}
# Every tag of the image this run builds.
variable "TAGS" {}
variable "SOURCE_COMMIT" { default = "" }
variable "BUILD_DATE" { default = "" }

target "_common" {
  platforms = [PLATFORM]
  context   = "."
}

target "oss" {
  inherits   = ["_common"]
  dockerfile = "Dockerfile.oss"
  # Never from the cache: apt-get upgrade must bring the day's Debian updates (the gateway stage, with
  # the modules pinned to the base nginx, stays cached). Set here, on the target that has the stage:
  # unprivileged only reuses this target's result.
  no-cache-filter = ["os-updates"]
  args = {
    NGINX_BASE        = NGINX_BASE
    MIN_NGINX_VERSION = MIN_NGINX_VERSION
  }
}

target "unprivileged" {
  inherits   = ["_common"]
  dockerfile = "Dockerfile.unprivileged"
  contexts = {
    nginx-s3-gateway = "target:oss"
  }
  labels = {
    "org.opencontainers.image.title"          = "nginx-s3-gateway"
    "org.opencontainers.image.description"    = "NGINX S3 gateway, unprivileged (port 8080, user nginx), nginx ${NGINX_VERSION} (Debian ${DEBIAN})"
    "org.opencontainers.image.version"        = "${NGINX_VERSION}-unprivileged"
    "org.opencontainers.image.revision"       = SOURCE_COMMIT
    "org.opencontainers.image.created"        = BUILD_DATE
    "org.opencontainers.image.licenses"       = "Apache-2.0"
    "dev.nginx-s3-gateway.nginx-version"      = NGINX_VERSION
    "dev.nginx-s3-gateway.nginx-base"         = NGINX_BASE
  }
  tags = split(",", TAGS)
}
