# Minimal environment for running airline-club manager inside Docker
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install Java 11, basic tools, mysql-server/client for DB inside the container
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openjdk-11-jdk \
      sudo \
      curl \
      unzip \
      git \
      ca-certificates \
      mysql-server \
      mysql-client \
      bash \
      coreutils && \
    rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:$PATH"

# Create non-root user with passwordless sudo for installer
RUN useradd -m -s /bin/bash app && echo "app ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-app && chmod 440 /etc/sudoers.d/90-app

# Provide a dummy systemctl to satisfy scripts during image build (no systemd in Docker build)
RUN printf '#!/bin/sh\nexit 0\n' > /usr/bin/systemctl && chmod +x /usr/bin/systemctl

# Create workspace directory where host folders will be mounted
RUN mkdir -p /workspace
WORKDIR /workspace

# Clone manager repo into /opt and run install as non-root user during build
RUN git clone https://github.com/FOUNDATION-AI-BASED/airline-club-manager.git /opt/airline-club-manager && chown -R app:app /opt/airline-club-manager

# Start mysqld daemon (no systemd) and execute installer
RUN bash -lc 'mkdir -p /var/run/mysqld && chown -R mysql:mysql /var/run/mysqld /var/lib/mysql || true && mysqld --user=mysql --daemonize || true && su - app -c "export DOCKER_BUILD=true INSTALL_BLOCKING=true; cd /opt/airline-club-manager && chmod +x airline-club-manager.sh && ./airline-club-manager.sh install"'

# Expose MySQL default port (for macOS publishing via docker run)
EXPOSE 3306

# Default command keeps container alive for exec-based control
CMD ["bash", "-lc", "sleep infinity"]
