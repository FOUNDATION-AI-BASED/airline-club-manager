FROM ubuntu:22.04

# Suppress interactive prompts and minimize output
ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm
ENV SBT_OPTS="-Xms512m -Xmx2048m -XX:MaxMetaspaceSize=256m -XX:+UseG1GC -Dsbt.log.noformat=true"
ENV JAVA_OPTS="$SBT_OPTS"

# Install system dependencies with minimal output
RUN apt-get update -qq > /dev/null 2>&1 && \
    apt-get install -y -qq \
        openjdk-11-jdk \
        wget \
        curl \
        git \
        unzip \
        mariadb-server \
        mariadb-client \
        python3 \
        python3-pip \
        supervisor \
        > /dev/null 2>&1 && \
    apt-get clean > /dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/* > /dev/null 2>&1

# Install sbt
RUN echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" | tee /etc/apt/sources.list.d/sbt.list > /dev/null && \
    echo "deb https://repo.scala-sbt.org/scalasbt/debian /" | tee /etc/apt/sources.list.d/sbt_old.list > /dev/null && \
    curl -sL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" | apt-key add - > /dev/null 2>&1 && \
    apt-get update -qq > /dev/null 2>&1 && \
    apt-get install -y -qq sbt > /dev/null 2>&1

# Set up working directory
WORKDIR /app

# Copy airline club source code
COPY airline/ /app/airline/
COPY airline_manager.py /app/
COPY airline_manager.sh /app/
COPY manager_state.json /app/

# Create necessary directories
RUN mkdir -p /app/logs /app/pids /var/log/supervisor

# Configure MariaDB
RUN service mariadb start && \
    mysql -e "CREATE DATABASE IF NOT EXISTS airline_v2_1 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" && \
    mysql -e "CREATE USER IF NOT EXISTS 'sa'@'localhost' IDENTIFIED BY 'admin';" && \
    mysql -e "GRANT ALL PRIVILEGES ON airline_v2_1.* TO 'sa'@'localhost';" && \
    mysql -e "FLUSH PRIVILEGES;" && \
    service mariadb stop

# Pre-compile and publish airline-data (heavy operation done at build time)
RUN service mariadb start && \
    cd /app/airline/airline-data && \
    echo "[info] Pre-compiling airline-data..." && \
    sbt -Dsbt.log.noformat=true publishLocal > /dev/null 2>&1 && \
    echo "[info] Initializing database schema..." && \
    sbt -Dsbt.log.noformat=true "runMain com.patson.MainInit" > /dev/null 2>&1 && \
    service mariadb stop

# Configure supervisor for process management
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create startup script
COPY docker/start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Expose ports
EXPOSE 9000 3306

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:9000/airlines || exit 1

# Start services
CMD ["/app/start.sh"]