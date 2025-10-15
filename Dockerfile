# Minimal environment for running airline-club manager inside Docker
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# Install Java 8, basic tools, mysql-server/client for DB inside the container
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openjdk-8-jdk \
      curl \
      unzip \
      git \
      ca-certificates \
      mysql-server \
      mysql-client \
      bash \
      coreutils && \
    rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:$PATH"

# Create workspace directory where host folders will be mounted
RUN mkdir -p /workspace
WORKDIR /workspace

# Expose MySQL default port (for macOS publishing via docker run)
EXPOSE 3306

# Default command keeps container alive for exec-based control
CMD ["bash", "-lc", "sleep infinity"]
