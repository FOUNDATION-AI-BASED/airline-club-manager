#!/usr/bin/env python3
import os
import sys
import json
import shutil
import subprocess
import time
from pathlib import Path

WORKDIR = Path("/home/kali/airline-club-manager-test").resolve()
REPO_URL = "https://github.com/patsonluk/airline.git"
REPO_DIR = WORKDIR / "airline"
LOG_DIR = WORKDIR / "logs"
PID_DIR = WORKDIR / "pids"
STATE_FILE = WORKDIR / "manager_state.json"

# Steps tracked for resume capability
STEP_ORDER = [
    "clone_repo",
    "checkout_version",
    "install_jdk",
    "install_sbt",
    "install_mysql",
    "create_db",
    "publish_local",
    "set_map_key",
    "init_db_data",
]

DEFAULTS = {
    "branch": "master",  # or "v2"
    "db_name": "airline_v2_1",
    "db_user": "sa",
    "db_pass": "admin",
    "mysql_root_user": "root",
    "mysql_root_pass": "",  # prompt if empty
    "web_host": "0.0.0.0",
    "web_port": 9000,
}

def ensure_dirs():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    PID_DIR.mkdir(parents=True, exist_ok=True)


def load_state():
    ensure_dirs()
    if STATE_FILE.exists():
        with STATE_FILE.open("r") as f:
            return json.load(f)
    state = {"steps": {}, "config": DEFAULTS.copy()}
    save_state(state)
    return state


def save_state(state):
    with STATE_FILE.open("w") as f:
        json.dump(state, f, indent=2)


def log(msg):
    ensure_dirs()
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}\n"
    sys.stdout.write(line)
    with (LOG_DIR / "manager.log").open("a") as f:
        f.write(line)


def run(cmd, cwd=None, log_file_name=None, background=False, use_sudo=False):
    env = os.environ.copy()
    launcher = "sudo -S bash -lc" if use_sudo and os.geteuid() != 0 else "bash -lc"
    if background:
        log(f"Starting background: {launcher} '{cmd}' (cwd={cwd or WORKDIR})")
        lfpath = LOG_DIR / (log_file_name or "background.log")
        lf = lfpath.open("a")
        args = (["sudo", "-S", "bash", "-lc", cmd] if (use_sudo and os.geteuid() != 0) else ["bash", "-lc", cmd])
        proc = subprocess.Popen(args, cwd=str(cwd or WORKDIR), stdout=lf, stderr=lf, env=env)
        return proc
    else:
        log(f"Running: {launcher} '{cmd}' (cwd={cwd or WORKDIR})")
        args = (["sudo", "-S", "bash", "-lc", cmd] if (use_sudo and os.geteuid() != 0) else ["bash", "-lc", cmd])
        p = subprocess.run(args, cwd=str(cwd or WORKDIR), env=env)
        return p.returncode


def which(cmd):
    return shutil.which(cmd) is not None


# --- Operations ---

def op_clone_repo(state):
    if REPO_DIR.exists() and not (REPO_DIR / ".git").exists():
        # Directory exists but not a git repo; clean it up
        log(f"Found non-git directory at {REPO_DIR}, removing before clone...")
        try:
            shutil.rmtree(REPO_DIR)
            log(f"Removed {REPO_DIR}")
        except Exception as e:
            log(f"Failed to remove {REPO_DIR}: {e}")
            state["steps"]["clone_repo"] = False
            save_state(state)
            return False
    if REPO_DIR.exists() and (REPO_DIR / ".git").exists():
        log(f"Repo exists at {REPO_DIR}, pulling latest changes...")
        code = run("git fetch --all && git pull --ff-only", cwd=REPO_DIR)
        if code != 0:
            log("git pull failed. Trying with sudo...")
            code = run("git fetch --all && git pull --ff-only", cwd=REPO_DIR, use_sudo=True)
    else:
        log(f"Cloning {REPO_URL} to {REPO_DIR}...")
        code = run(f"git clone {REPO_URL} '{REPO_DIR}'")
        if code != 0:
            log("git clone failed. Trying with sudo...")
            code = run(f"git clone {REPO_URL} '{REPO_DIR}'", use_sudo=True)
    # Verify clone produced expected subprojects
    ok = (code == 0) and (REPO_DIR / "airline-data").exists() and (REPO_DIR / "airline-web").exists()
    if not ok:
        log(f"Clone validation failed: expected subdirectories not found under {REPO_DIR}")
    state["steps"]["clone_repo"] = ok
    save_state(state)
    return ok


def op_checkout_version(state):
    branch = state["config"].get("branch", DEFAULTS["branch"])
    log(f"Checking out branch/tag: {branch}")
    code = run(f"git checkout {branch}", cwd=REPO_DIR)
    if code != 0:
        log("git checkout failed. Trying with sudo...")
        code = run(f"git checkout {branch}", cwd=REPO_DIR, use_sudo=True)
    state["steps"]["checkout_version"] = (code == 0)
    save_state(state)
    return code == 0


def op_install_jdk(state):
    log("Installing OpenJDK (>=8)...")
    # Prefer OpenJDK 11
    code = run("apt-get update && apt-get install -y openjdk-11-jdk", use_sudo=True)
    state["steps"]["install_jdk"] = (code == 0)
    save_state(state)
    return code == 0


def op_install_sbt(state):
    log("Installing sbt (Scala build tool)...")
    # Try direct install; if not present, inform user
    code = run("apt-get update && apt-get install -y sbt", use_sudo=True)
    if code != 0:
        log("sbt installation via apt failed. Please install sbt manually from https://www.scala-sbt.org/")
    state["steps"]["install_sbt"] = which("sbt")
    save_state(state)
    return state["steps"]["install_sbt"]


def op_install_mysql(state):
    log("Installing MariaDB/MySQL server (may already be installed)...")
    # Prefer mariadb-server on Debian/Kali
    code = run("apt-get update && apt-get install -y mariadb-server", use_sudo=True)
    if code != 0:
        log("mariadb-server installation failed, trying mysql-server...")
        code = run("apt-get update && apt-get install -y mysql-server", use_sudo=True)
    state["steps"]["install_mysql"] = (code == 0)
    save_state(state)
    return code == 0


def _mysql_exec(sql, user, pwd):
    # Escape single quotes safely
    safe = sql.replace("'", "'\\''")
    if user == "root":
        # Always use sudo for root to leverage unix_socket auth when available
        pwd_opt = f"-p{pwd}" if (pwd) else ""
        return run(f"mysql -u root {pwd_opt} -e '{safe}'", use_sudo=True)
    else:
        pwd_opt = f"-p{pwd}" if pwd else ""
        return run(f"mysql -u {user} {pwd_opt} -e '{safe}'")


def op_create_db(state):
    cfg = state["config"]
    db = cfg["db_name"]
    sa_user = cfg["db_user"]
    sa_pass = cfg["db_pass"]

    root_user = cfg.get("mysql_root_user", "root")
    root_pass = cfg.get("mysql_root_pass", "")

    log("Creating database and service account...")
    sqls = [
        f"CREATE DATABASE IF NOT EXISTS {db} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;",
        f"CREATE USER IF NOT EXISTS '{sa_user}'@'localhost' IDENTIFIED BY '{sa_pass}';",
        f"GRANT ALL PRIVILEGES ON {db}.* TO '{sa_user}'@'localhost';",
        "FLUSH PRIVILEGES;",
    ]
    for sql in sqls:
        code = _mysql_exec(sql, root_user, root_pass)
        # Fallback: handle older servers where CREATE USER IF NOT EXISTS is unsupported
        if code != 0 and sql.strip().startswith("CREATE USER IF NOT EXISTS"):
            alt = f"ALTER USER '{sa_user}'@'localhost' IDENTIFIED BY '{sa_pass}';"
            code = _mysql_exec(alt, root_user, root_pass)
        if code != 0:
            log("MySQL command failed. If this is due to auth, please enter MySQL root password.")
            root_pass = input("Enter MySQL root password (leave blank to retry without): ")
            cfg["mysql_root_pass"] = root_pass
            save_state(state)
            code = _mysql_exec(sql, root_user, root_pass)
            if code != 0 and sql.strip().startswith("CREATE USER IF NOT EXISTS"):
                alt = f"ALTER USER '{sa_user}'@'localhost' IDENTIFIED BY '{sa_pass}';"
                code = _mysql_exec(alt, root_user, root_pass)
            if code != 0:
                log(f"Failed to execute SQL: {sql}")
                state["steps"]["create_db"] = False
                save_state(state)
                return False

    # If MySQL 8.x detected, switch the service account to mysql_native_password (legacy JDBC compatibility)
    if run("mysql --version | grep -E 'Ver 8|Distrib 8'", use_sudo=False) == 0:
        _mysql_exec(
            f"ALTER USER '{sa_user}'@'localhost' IDENTIFIED WITH mysql_native_password BY '{sa_pass}';",
            root_user,
            root_pass,
        )

    state["steps"]["create_db"] = True
    save_state(state)
    return True


def op_publish_local(state):
    # airline-web depends on airline-data; publishLocal from airline-data
    data_dir = REPO_DIR / "airline-data"
    log("Publishing airline-data locally (sbt publishLocal)...")
    if not data_dir.exists():
        log(f"Missing {data_dir}. Attempting to clone the repository...")
        if not op_clone_repo(state):
            state["steps"]["publish_local"] = False
            save_state(state)
            return False
        # Ensure correct branch
        op_checkout_version(state)
    if which("activator"):
        cmd = "activator publishLocal"
    else:
        cmd = "sbt publishLocal"
    code = run(cmd, cwd=data_dir)
    if code != 0:
        log("publishLocal failed.")
        state["steps"]["publish_local"] = False
        save_state(state)
        return False
    state["steps"]["publish_local"] = True
    save_state(state)
    return True


def op_set_map_key_value(state, key):
    conf_path = REPO_DIR / "airline-web" / "conf" / "application.conf"
    if not conf_path.exists():
        log(f"Cannot find {conf_path}")
        return False
    if not key:
        log("No key provided.")
        return False
    text = conf_path.read_text()
    import re
    new_text, n = re.subn(r"(?m)^\s*google\.mapKey\s*=\s*\".*?\"", f'google.mapKey = "{key}"', text)
    if n == 0:
        new_text = text + f"\ngoogle.mapKey = \"{key}\"\n"
    conf_path.write_text(new_text)
    log("Updated google.mapKey in application.conf (non-interactive)")
    state["steps"]["set_map_key"] = True
    save_state(state)
    return True


def op_config_host_port_values(state, host, port):
    if not host:
        host = "0.0.0.0"
    try:
        port_int = int(port)
    except Exception:
        port_int = 9000
    state["config"]["web_host"] = host
    state["config"]["web_port"] = port_int
    save_state(state)
    conf_path = REPO_DIR / "airline-web" / "conf" / "application.conf"
    if conf_path.exists():
        text = conf_path.read_text()
        block = f'\n# Manager-added: Play server HTTP settings (effective in production)\nhttp {{\n  address = "{host}"\n  port = {port_int}\n}}\n'
        conf_path.write_text(text + block)
        log("Updated application.conf with http address/port for production runs.")
    else:
        log("application.conf not found; saved config only.")
    return True


def op_config_banner_value(state, enabled_str):
    enabled = str(enabled_str).lower() in ("y", "yes", "true", "1")
    conf_path = REPO_DIR / "airline-web" / "conf" / "application.conf"
    if conf_path.exists():
        text = conf_path.read_text()
        import re
        new_text, n = re.subn(r'(?m)^\s*bannerEnabled\s*=\s*(true|false)', f'bannerEnabled = {"true" if enabled else "false"}', text)
        if n == 0:
            new_text = text + f'\nbannerEnabled = {"true" if enabled else "false"}\n'
        conf_path.write_text(new_text)
        log(f"Set bannerEnabled = {enabled} in application.conf (non-interactive)")
    else:
        log("application.conf not found.")
    state["config"]["banner_enabled"] = enabled
    save_state(state)
    return True


def op_config_elasticsearch_values(state, enabled_str, es_host, es_port):
    use_es = str(enabled_str).lower() in ("y", "yes", "true", "1")
    state["config"]["use_elasticsearch"] = use_es
    state["config"]["elasticsearch_host"] = es_host or "localhost"
    try:
        state["config"]["elasticsearch_port"] = int(es_port)
    except Exception:
        state["config"]["elasticsearch_port"] = 9200
    save_state(state)
    conf_path = REPO_DIR / "airline-web" / "conf" / "application.conf"
    if conf_path.exists():
        text = conf_path.read_text()
        block = f'\n# Manager-added: Elasticsearch settings (ensure keys match upstream if required)\nsearch.elasticsearch.enabled = {"true" if use_es else "false"}\nsearch.elasticsearch.host = "{state["config"]["elasticsearch_host"]}"\nsearch.elasticsearch.port = {state["config"]["elasticsearch_port"]}\n'
        conf_path.write_text(text + block)
        log("Appended Elasticsearch configuration block to application.conf (non-interactive)")
    else:
        log("application.conf not found.")
    return True


def op_setup_reverse_proxy_values(state, domain, backend_port, cert_path, key_path, assets_path=None):
    domain = domain.strip()
    if not domain:
        log("Domain must be provided.")
        return False
    if not backend_port:
        backend_port = str(state['config'].get('web_port', 9000))
    if not assets_path:
        assets_path = str(REPO_DIR / "airline-web" / "public")
    log("Installing nginx if missing and creating reverse proxy configuration (non-interactive)...")
    run("apt-get update && apt-get install -y nginx", use_sudo=True)
    conf_content = f"""
server {{
  listen 443 ssl http2;
  listen [::] ssl http2;
  server_name {domain};

  ssl_certificate      {cert_path};
  ssl_certificate_key  {key_path};

  add_header X-Frame-Options SAMEORIGIN;
  add_header X-Xss-Protection \"1; mode=block\" always;
  add_header X-Content-Type-Options \"nosniff\" always;
  add_header Referrer-Policy \"strict-origin-when-cross-origin\";
  access_log /var/log/nginx/{domain}.access.log;
  error_log /var/log/nginx/{domain}.error.log;

  location /assets {{
    alias {assets_path};
    access_log on;
    expires 30d;
  }}

  location / {{
    proxy_pass http://localhost:{backend_port};
    proxy_pass_header Content-Type;
    proxy_read_timeout     60;
    proxy_connect_timeout  60;
    proxy_redirect         off;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_cache_bypass $http_upgrade;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }}
}}
"""
    conf_path = Path(f"/etc/nginx/sites-available/{domain}.conf")
    try:
        with conf_path.open("w") as f:
            f.write(conf_content)
        run(f"ln -sf {conf_path} /etc/nginx/sites-enabled/{domain}.conf", use_sudo=True)
        run("nginx -t", use_sudo=True)
        run("nginx -s reload", use_sudo=True)
        log(f"Nginx reverse proxy configured for {domain} forwarding to localhost:{backend_port}")
        state["config"]["reverse_proxy_domain"] = domain
        save_state(state)
        return True
    except Exception as e:
        log(f"Failed to setup Nginx reverse proxy: {e}")
        return False


def op_start_web(state):
    web_dir = REPO_DIR / "airline-web"
    host = state["config"].get("web_host", "0.0.0.0")
    port = state["config"].get("web_port", 9000)
    log(f"Starting airline-web server on {host}:{port} as background...")
    if which("activator"):
        cmd = f"activator -Dhttp.port={port} -Dhttp.address={host} run"
    else:
        cmd = f"sbt -Dhttp.port={port} -Dhttp.address={host} run"
    proc = run(cmd, cwd=web_dir, background=True, log_file_name="web.log")
    pid_file = PID_DIR / "web.pid"
    pid_file.write_text(str(proc.pid))
    log(f"Web server started with PID {proc.pid}. Logs -> {LOG_DIR / 'web.log'} (expected at http://{host}:{port})")


def op_stop_web():
    pid_file = PID_DIR / "web.pid"
    if not pid_file.exists():
        log("No web server PID file found.")
        return
    pid = int(pid_file.read_text().strip())
    try:
        os.kill(pid, 15)  # SIGTERM
        log(f"Sent SIGTERM to web server PID {pid}.")
    except Exception as e:
        log(f"Failed to stop web server: {e}")


def op_uninstall(state):
    log("Stopping services and removing cloned repo...")
    op_stop_simulation()
    op_stop_web()
    if REPO_DIR.exists():
        try:
            shutil.rmtree(REPO_DIR)
            log(f"Removed {REPO_DIR}")
        except Exception as e:
            log(f"Failed to remove {REPO_DIR}: {e}")
    # Reset state
    save_state({"steps": {}, "config": DEFAULTS.copy()})
    log("Uninstall completed (state reset).")


def print_menu(state):
    print("\n================ Airline Club Manager =================")
    print(f"Workspace: {WORKDIR}")
    print(f"Repo: {REPO_DIR} (branch/tag: {state['config'].get('branch')})")
    print("-----------------------------------------------------")
    print("1) Full installation and configuration")
    print("2) Install dependencies (JDK, sbt, MariaDB/MySQL)")
    print("3) Clone/Update repository")
    print("4) Checkout version (master/v2)")
    print("5) Publish airline-data locally")
    print("6) Initialize DB data (MainInit)")
    print("7) Start background simulation")
    print("8) Start web server")
    print("9) Stop background simulation")
    print("10) Stop web server")
    print("11) Configure Google Map API key")
    print("12) Uninstall (stop servers, remove repo)")
    print("13) View logs directory path")
    print("14) Resume entire installation (next incomplete step)")
    print("15) Resume from specific step")
    print("16) Configure server host/port")
    print("17) Configure bannerEnabled")
    print("18) Configure Elasticsearch usage")
    print("19) Configure trusted hosts")
    print("20) Setup Nginx reverse proxy")
    print("0) Exit")
    print("-----------------------------------------------------")


def resume_next(state):
    for step in STEP_ORDER:
        if not state["steps"].get(step, False):
            log(f"Resuming step: {step}")
            return run_step_by_name(state, step)
    log("All tracked steps completed.")
    return True


def run_step_by_name(state, step):
    mapping = {
        "clone_repo": op_clone_repo,
        "checkout_version": op_checkout_version,
        "install_jdk": op_install_jdk,
        "install_sbt": op_install_sbt,
        "install_mysql": op_install_mysql,
        "create_db": op_create_db,
        "publish_local": op_publish_local,
        "set_map_key": op_set_map_key,
        "init_db_data": op_init_db_data,
    }
    func = mapping.get(step)
    if not func:
        log(f"Unknown step: {step}")
        return False
    return func(state)


def op_set_map_key(state):
    key = input("Enter Google Map API key (press Enter to skip): ").strip()
    if not key:
        log("Skipped setting map key.")
        state["steps"]["set_map_key"] = False
        save_state(state)
        return False
    return op_set_map_key_value(state, key)


def op_init_db_data(state):
    data_dir = REPO_DIR / "airline-data"
    log("Initializing DB data via MainInit...")
    if which("activator"):
        cmd = "activator 'runMain com.patson.init.MainInit'"
    else:
        cmd = "sbt 'runMain com.patson.init.MainInit'"
    code = run(cmd, cwd=data_dir)
    state["steps"]["init_db_data"] = (code == 0)
    save_state(state)
    return code == 0


def op_start_simulation(state):
    data_dir = REPO_DIR / "airline-data"
    log("Starting background simulation (MainSimulation) as background...")
    if which("activator"):
        cmd = "activator 'runMain com.patson.MainSimulation'"
    else:
        cmd = "sbt 'runMain com.patson.MainSimulation'"
    proc = run(cmd, cwd=data_dir, background=True, log_file_name="simulation.log")
    pid_file = PID_DIR / "simulation.pid"
    pid_file.write_text(str(proc.pid))
    log(f"Simulation started with PID {proc.pid}. Logs -> {LOG_DIR / 'simulation.log'}")


def op_stop_simulation():
    pid_file = PID_DIR / "simulation.pid"
    if not pid_file.exists():
        log("No simulation PID file found.")
        return
    try:
        pid = int(pid_file.read_text().strip())
        os.kill(pid, 15)  # SIGTERM
        log(f"Sent SIGTERM to simulation PID {pid}.")
    except Exception as e:
        log(f"Failed to stop simulation: {e}")


def op_config_host_port(state):
    host = input("Enter host/address (default 0.0.0.0): ").strip() or "0.0.0.0"
    port = input("Enter port (default 9000): ").strip() or "9000"
    return op_config_host_port_values(state, host, port)


def op_config_banner(state):
    val = input("Enable banner? (yes/no, default no): ").strip().lower()
    if not val:
        val = "no"
    return op_config_banner_value(state, val)


def op_config_elasticsearch(state):
    use_es_input = input("Enable Elasticsearch-backed flight search? (yes/no, default no): ").strip().lower()
    if not use_es_input:
        use_es_input = "no"
    es_host = "localhost"
    es_port = "9200"
    if use_es_input in ("y","yes","true","1"):
        es_host = input("Elasticsearch host (default localhost): ").strip() or "localhost"
        es_port = input("Elasticsearch port (default 9200): ").strip() or "9200"
    return op_config_elasticsearch_values(state, use_es_input, es_host, es_port)


def op_setup_reverse_proxy(state):
    domain = input("Enter domain (e.g., domain.com): ").strip()
    default_port = str(state['config'].get('web_port', 9000))
    backend_port = input(f"Backend port (default {default_port}): ").strip() or default_port
    cert_path = input("SSL certificate path (e.g., /etc/ssl/certs/domain.crt): ").strip()
    key_path = input("SSL certificate key path (e.g., /etc/ssl/private/domain.key): ").strip()
    assets_path_default = str(REPO_DIR / "airline-web" / "public")
    assets_path = input(f"Assets path (default {assets_path_default}): ").strip() or assets_path_default
    return op_setup_reverse_proxy_values(state, domain, backend_port, cert_path, key_path, assets_path)

# New: trusted hosts configuration

def op_config_trusted_hosts_value(state, hosts_str):
    hosts = [h.strip() for h in (hosts_str or "").split(",") if h.strip()]
    if not hosts:
        hosts = ["localhost", "127.0.0.1"]
    state["config"]["trusted_hosts"] = hosts
    save_state(state)
    conf_path = REPO_DIR / "airline-web" / "conf" / "application.conf"
    if conf_path.exists():
        text = conf_path.read_text()
        # Build allowed list without backslashes inside f-string expression
        allowed_list = ", ".join(["\"{}\"".format(h) for h in hosts])
        block = (
            "\n# Manager-added: Trusted hosts for Play\n"
            "play.filters.hosts {\n"
            f"  allowed = [{allowed_list}]\n"
            "}\n"
        )
        conf_path.write_text(text + block)
        log(f"Appended trusted hosts to application.conf: {hosts}")
    else:
        log("application.conf not found.")
    return True


def op_config_trusted_hosts(state):
    default_hosts = "localhost, 127.0.0.1"
    hosts_input = input(f"Enter comma-separated trusted hosts (default: {default_hosts}): ").strip()
    if not hosts_input:
        hosts_input = default_hosts
    return op_config_trusted_hosts_value(state, hosts_input)

# New helper to bundle dependencies installation

def op_install_deps(state):
    log("Installing dependencies and creating database...")
    ok1 = op_install_jdk(state)
    ok2 = op_install_sbt(state)
    ok3 = op_install_mysql(state)
    ok4 = op_create_db(state)
    ok = ok1 and ok2 and ok3 and ok4
    log("install_deps completed successfully." if ok else "install_deps completed with errors.")
    return ok

# New: Full installation and configuration wizard

def op_full_install(state):
    log("Starting full installation and configuration wizard...")
    # Clone/update repo
    if not op_clone_repo(state):
        log("Clone/update failed; continuing for troubleshooting.")
    # Branch selection
    branch = input(f"Branch or tag to checkout (default {state['config'].get('branch','master')}): ").strip() or state['config'].get('branch','master')
    state['config']['branch'] = branch
    save_state(state)
    if not op_checkout_version(state):
        log("Checkout failed; continuing for troubleshooting.")
    # Install deps + DB
    op_install_deps(state)
    # Publish airline-data locally
    op_publish_local(state)
    # Initialize DB data
    op_init_db_data(state)
    # Host/port
    op_config_host_port(state)
    # Banner
    op_config_banner(state)
    # Elasticsearch
    op_config_elasticsearch(state)
    # Trusted hosts
    op_config_trusted_hosts(state)
    # Google Map key (optional)
    op_set_map_key(state)
    log("Full installation and configuration completed. Review logs for any errors.")
    return True


def cli_main(argv):
    ensure_dirs()
    state = load_state()
    if not argv:
        main()
        return
    cmd = argv[0]
    try:
        if cmd == "install_deps":
            op_install_deps(state)
        elif cmd == "full_install":
            op_full_install(state)
        elif cmd == "clone":
            op_clone_repo(state)
        elif cmd == "checkout":
            branch = argv[1] if len(argv) > 1 else state["config"].get("branch", "master")
            state["config"]["branch"] = branch
            save_state(state)
            op_checkout_version(state)
        elif cmd == "publish_local":
            op_publish_local(state)
        elif cmd == "init_db":
            op_create_db(state)
        elif cmd == "start_web":
            op_start_web(state)
        elif cmd == "stop_web":
            op_stop_web()
        elif cmd == "start_simulation":
            op_start_simulation(state)
        elif cmd == "stop_simulation":
            op_stop_simulation()
        elif cmd == "set_map_key":
            key = argv[1] if len(argv) > 1 else ""
            op_set_map_key_value(state, key)
        elif cmd == "config_host_port":
            host = argv[1] if len(argv) > 1 else "0.0.0.0"
            port = argv[2] if len(argv) > 2 else "9000"
            op_config_host_port_values(state, host, port)
        elif cmd == "config_banner":
            val = argv[1] if len(argv) > 1 else "no"
            op_config_banner_value(state, val)
        elif cmd == "config_elasticsearch":
            enabled = argv[1] if len(argv) > 1 else "no"
            es_host = argv[2] if len(argv) > 2 else "localhost"
            es_port = argv[3] if len(argv) > 3 else "9200"
            op_config_elasticsearch_values(state, enabled, es_host, es_port)
        elif cmd == "config_trusted_hosts":
            hosts = argv[1] if len(argv) > 1 else "localhost,127.0.0.1"
            op_config_trusted_hosts_value(state, hosts)
        elif cmd == "setup_reverse_proxy":
            domain = argv[1] if len(argv) > 1 else ""
            backend_port = argv[2] if len(argv) > 2 else str(state["config"].get("web_port", 9000))
            cert_path = argv[3] if len(argv) > 3 else ""
            key_path = argv[4] if len(argv) > 4 else ""
            assets_path = argv[5] if len(argv) > 5 else None
            op_setup_reverse_proxy_values(state, domain, backend_port, cert_path, key_path, assets_path)
        elif cmd == "resume_next":
            resume_next(state)
        elif cmd == "uninstall":
            op_uninstall(state)
        else:
            log(f"Unknown command: {cmd}")
    except Exception as e:
        log(f"CLI error: {e}")


def main():
    ensure_dirs()
    state = load_state()
    while True:
        print_menu(state)
        choice = input("Enter choice: ").strip()
        if choice == "1":
            op_full_install(state)
        elif choice == "2":
            op_install_deps(state)
        elif choice == "3":
            op_clone_repo(state)
        elif choice == "4":
            op_checkout_version(state)
        elif choice == "5":
            op_publish_local(state)
        elif choice == "6":
            op_init_db_data(state)
        elif choice == "7":
            op_start_simulation(state)
        elif choice == "8":
            op_start_web(state)
        elif choice == "9":
            op_stop_simulation()
        elif choice == "10":
            op_stop_web()
        elif choice == "11":
            op_set_map_key(state)
        elif choice == "12":
            op_uninstall(state)
        elif choice == "13":
            print(f"Logs directory: {LOG_DIR}")
        elif choice == "14":
            resume_next(state)
        elif choice == "15":
            step = input(f"Enter step to run ({', '.join(STEP_ORDER)}): ").strip()
            run_step_by_name(state, step)
        elif choice == "16":
            op_config_host_port(state)
        elif choice == "17":
            op_config_banner(state)
        elif choice == "18":
            op_config_elasticsearch(state)
        elif choice == "19":
            op_config_trusted_hosts(state)
        elif choice == "20":
            op_setup_reverse_proxy(state)
        elif choice == "0":
            log("Exiting.")
            break
        else:
            log("Invalid choice.")

if __name__ == "__main__":
    # Dispatch CLI commands or open interactive menu by default
    cli_main(sys.argv[1:])