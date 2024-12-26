#!/usr/bin/env python3
import os
import sys
import configparser
import logging
import subprocess
import shutil
import ast
from textwrap import dedent
from datetime import datetime
from enum import Enum

SCRIPT_VERSION = "1.0.0"
CONFIG_FILE = "aws_dcgm_exporter.cfg"
METRICS_FILE = "dcgm_metrics.csv"
LOG_FILE = "/tmp/setup_aws_dcgm_exporter.log"
CW_BASEDIR = "/opt/aws/amazon-cloudwatch-agent"
CWAGENT_LOG = "{}/logs/amazon-cloudwatch-agent.log".format(CW_BASEDIR)
CWAGENT_CTL = "/usr/bin/sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl"
CWAGENT_CONFIG_BASE = "cloudwatch_config_base.json"
CWAGENT_CONFIG_NVIDIA_SMI = "cloudwatch_config_nvidia_smi.json"
CWAGENT_CONFIG_NVIDIA_DCGM = "cloudwatch_config_nvidia_dcgm.json"
PROMETHEUS_YAML = "{}/var/prometheus.yaml".format(CW_BASEDIR)
DCGM_EXPORTER_CONTAINER_NAME = "dcgm-exporter"
EXPECTED_METRICS_FILE_PATH = "/home/ubuntu/aws-dcgm-exporter/{}".format(METRICS_FILE)
TIME_FORMAT = "%I:%M%p %B-%d-%Y"
CURRENT_SCRIPT = os.path.realpath(__file__)


def log_proc_output(proc):
    """
    Helper to log output of process to log file.
    """
    print("\nStdout --->:\n" + str(proc.stdout) + "\nStderr --->:\n" + str(proc.stderr) + "\n", file=open(LOG_FILE, 'a'))


# Configuration status for CloudWatch agent.
class AgentConfigStatus(Enum):
    # Never installed agent.
    NOT_INSTALLED = 1

    # Installed package, but not configured yet.
    NOT_CONFIGURED = 2

    # Configured with 'base' Turbo metrics (mem_available).
    CONFIGURED_BASE_METRICS = 3

    # Whether Nvidia DCGM metrics are configured.
    CONFIGURED_NVIDIA_SMI_METRICS = 4

    # Whether Nvidia DCGM metrics are configured.
    CONFIGURED_NVIDIA_DCGM_METRICS = 5

    # Error configuration, needs manual intervention, we bail out.
    ERROR = 6

    # Some other unexpected status. We bail out.
    UNKNOWN = 7


# Runtime status for CloudWatch agent.
class AgentRuntimeStatus(Enum):
    # Not currently running.
    STOPPED = 1

    # Currently up and running.
    RUNNING = 2

    # Some other unexpected status. We bail out.
    UNKNOWN = 3


def get_agent_status():
    """
    Gets the current config and runtime status for the CloudWatch agent.
    """

    # If never installed, return that status.
    if not os.path.exists("{}/bin".format(CW_BASEDIR)):
        return AgentConfigStatus.NOT_INSTALLED, AgentRuntimeStatus.UNKNOWN

    cw_cmd = "/usr/bin/sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a status"
    proc = subprocess.run(cw_cmd, shell=True, capture_output=True)
    log_proc_output(proc)

    if proc.returncode != 0:
        return AgentConfigStatus.ERROR, AgentRuntimeStatus.UNKNOWN

    # Parse output and extract status.
    runtime_status = AgentRuntimeStatus.UNKNOWN
    status_dict = ast.literal_eval(proc.stdout.decode("utf-8"))
    if 'status' in status_dict:
        if status_dict['status'] == 'running':
            runtime_status = AgentRuntimeStatus.RUNNING
        elif status_dict['status'] == 'stopped':
            runtime_status = AgentRuntimeStatus.STOPPED

    if 'configstatus' not in status_dict or status_dict['configstatus'] != 'configured':
        return AgentConfigStatus.NOT_CONFIGURED, runtime_status

    # CloudWatch agent is configured. Try to check what is configured.
    # Kind of crude way to determining which metrics are available, check in the .d dir.
    config_dir = "{}/etc/amazon-cloudwatch-agent.d".format(CW_BASEDIR)

    print("Checking contents of config dir: {}".format(config_dir), file=open(LOG_FILE, 'a'))
    list_cmd = "/usr/bin/ls -ltr {}".format(config_dir)
    proc = subprocess.run(list_cmd, shell=True, capture_output=True)
    log_proc_output(proc)

    print("Checking whether DCGM metrics are configured", file=open(LOG_FILE, 'a'))
    dcgm_cmd = "/usr/bin/grep \"DCGM_FI_PROF_DRAM_ACTIVE\" {}/*".format(config_dir)
    proc = subprocess.run(dcgm_cmd, shell=True, capture_output=True)
    log_proc_output(proc)
    if proc.returncode == 0:
        return AgentConfigStatus.CONFIGURED_NVIDIA_DCGM_METRICS, runtime_status

    print("Checking whether SMI metrics are configured", file=open(LOG_FILE, 'a'))
    smi_cmd = "/usr/bin/grep \"utilization_gpu\" {}/*".format(config_dir)
    proc = subprocess.run(smi_cmd, shell=True, capture_output=True)
    log_proc_output(proc)
    if proc.returncode == 0:
        return AgentConfigStatus.CONFIGURED_NVIDIA_SMI_METRICS, runtime_status

    print("Checking whether base (memory) metrics are configured", file=open(LOG_FILE, 'a'))
    base_cmd = "/usr/bin/grep \"mem_available\" {}/*".format(config_dir)
    proc = subprocess.run(base_cmd, shell=True, capture_output=True)
    log_proc_output(proc)
    if proc.returncode == 0:
        return AgentConfigStatus.CONFIGURED_BASE_METRICS, runtime_status

    return AgentConfigStatus.NOT_CONFIGURED, runtime_status


def check_cloudwatch_agent():
    """
    Check if CloudWatch agent is currently installed or not. If not installed, exit.
    Otherwise, returns the config and runtime status back.
    """
    log.info("Getting current CloudWatch agent status...")
    config_status, runtime_status = get_agent_status()
    log.info("Config status: " + config_status.name + ". Runtime status: " + runtime_status.name)

    if config_status == AgentConfigStatus.NOT_INSTALLED or\
            config_status == AgentConfigStatus.ERROR or \
            config_status == AgentConfigStatus.UNKNOWN or \
            runtime_status == AgentRuntimeStatus.UNKNOWN:
        on_exit("Unsupported CloudWatch agent status ({}, {}). Cannot proceed with configuration."
                .format(config_status, runtime_status))
    return config_status, runtime_status


def write_prometheus_yaml():
    """
    Prints the prometheus.yaml file contents.
    """
    polling_interval = config['general']['polling.interval.secs']
    prometheus_port = config['dcgm-exporter']['prometheus.port']

    instance_id = get_instance_value("instance-id")
    instance_name = config['general']['instance.name']
    if instance_name is None:
        instance_name = ''

    log.info("Writing " + PROMETHEUS_YAML + " file.")
    log.info("Current instance-id: " + instance_id + ", instance name: " + instance_name)

    yaml_template = dedent("""
global:
  scrape_interval: {}s
  evaluation_interval: {}s
  scrape_timeout: {}s
scrape_configs:
  - job_name: 'dcgm_exporter'
    static_configs:
      - targets: ['localhost:{}']
        labels:
          InstanceName: '{}'
          InstanceId: '{}'    
    """).strip("\n")

    tmp_file = "/tmp/" + os.path.basename(PROMETHEUS_YAML)
    print(yaml_template.format(polling_interval, polling_interval, polling_interval, prometheus_port,
                               instance_name, instance_id), file=open(tmp_file, 'w'))
    copy_cmd = "/usr/bin/sudo cp " + tmp_file + " " + PROMETHEUS_YAML
    proc = subprocess.run(copy_cmd, shell=True, capture_output=True)
    log_proc_output(proc)
    os.remove(tmp_file)

    if proc.returncode != 0:
        on_exit("Could not create Prometheus yaml config. Return code: " + proc.returncode)

    log.info("Successfully created Prometheus yaml config.")


def check_dcgm_docker():
    """
    Checks status of DCGM docker container. Will exit if error.
    """
    check_cmd = "/usr/bin/docker container inspect --format '{{.State.Status}}' " + DCGM_EXPORTER_CONTAINER_NAME
    print("Detecting DCGM exporter docker container status. Cmd: " + check_cmd, file=open(LOG_FILE, 'a'))
    proc = subprocess.run(check_cmd, shell=True, capture_output=True)
    log_proc_output(proc)
    if proc.returncode != 0:
        log.info("No current DCGM exporter docker container running.")
        return "not_running"
    container_state = proc.stdout.decode("utf-8").strip()
    log.info("Found status of DCGM exporter docker container: '{}'".format(container_state))
    return container_state


def docker_setup_dcgm_exporter():
    """
    Performs DCGM Exporter docker setup.
    """
    log.info("Checking if DCGM Exporter docker container '{}' is running...".format(DCGM_EXPORTER_CONTAINER_NAME))
    check_cmd = "/usr/bin/docker ps | grep '{}$'".format(DCGM_EXPORTER_CONTAINER_NAME)
    proc = subprocess.run(check_cmd, shell=True, capture_output=True)
    log_proc_output(proc)
    if proc.returncode == 0:
        log.info("DCGM Exporter docker container is already running.")
        return

    dcgm_state = check_dcgm_docker()
    if dcgm_state == 'running':
        log.info("DCGM exporter docker container is already running.")
        return
    if dcgm_state == 'exited':
        log.info("DCGM exporter docker container not running, trying to start it...")
        start_cmd = "/usr/bin/sudo /usr/bin/docker start {}".format(DCGM_EXPORTER_CONTAINER_NAME)
        proc = subprocess.run(start_cmd, shell=True, capture_output=True)
        log_proc_output(proc)

        # check status once more. If not running, we try to run below.
        dcgm_state = check_dcgm_docker()
        if dcgm_state == 'running':
            log.info("Successfully started up DCGM exporter docker container.")
            return

    # In 'not_running' state, so we try to set it up here.
    polling_frequency_millis = int(config['general']['polling.interval.secs']) * 1000
    prometheus_port = config['dcgm-exporter']['prometheus.port']
    package_version = config['dcgm-exporter']['package.version']
    image_version = "nvcr.io/nvidia/k8s/{}".format(package_version)
    log.info("Setting up DCGM Exporter docker container (image: {})...".format(image_version))

    source_metrics_file = os.path.realpath(METRICS_FILE)
    if not os.path.exists(source_metrics_file):
        on_exit("DCGM metrics CSV file " + source_metrics_file + " does not exist.")

    # We need this path to be fixed, as docker is using it.
    if source_metrics_file != EXPECTED_METRICS_FILE_PATH:
        on_exit("Metrics file path " + source_metrics_file + " doesn't match expected: " + EXPECTED_METRICS_FILE_PATH)

    docker_cmd = "/usr/bin/sudo /usr/bin/docker run --pid=host --privileged -e DCGM_EXPORTER_INTERVAL=%s" \
                 " --gpus all --restart=always -d -v /proc:/proc -v %s:/etc/dcgm-exporter/default-counters.csv" \
                 " -p %s:%s --name %s %s" % (polling_frequency_millis, source_metrics_file, prometheus_port,
                                             prometheus_port, DCGM_EXPORTER_CONTAINER_NAME, image_version)

    log.info("Executing docker command: \n" + docker_cmd + "\nPlease wait...")
    proc = subprocess.run(docker_cmd, shell=True, capture_output=True)
    log_proc_output(proc)

    if proc.returncode != 0:
        on_exit("Error running DCGM Exporter docker setup.")
    log.info("Successfully setup DCGM Exporter docker container.")


def start_stop_agent(operation):
    """
    Helper for starting and stopping CloudWatch agent.
    """
    op_display = ''
    if operation == 'stop':
        op_display = 'Stopping'
    elif operation == 'start':
        op_display = 'Starting'

    if op_display != '':
        log.info(op_display + " CloudWatch agent...")
        stop_cmd = CWAGENT_CTL + " -a " + operation
        proc = subprocess.run(stop_cmd, shell=True, capture_output=True)
        log_proc_output(proc)


def configure_agent(config_file):
    """
    Configures (appends) the agent with the specified config file. Assumes agent is currently stopped.
    config_file: File to configure with.
    """
    log.info("Appending agent config " + config_file + "...")
    start_cmd = CWAGENT_CTL + " -a append-config -m ec2 -c file:" + config_file
    proc = subprocess.run(start_cmd, shell=True, capture_output=True)
    log_proc_output(proc)


def get_instance_value(instance_type):
    """
    Gets the value of instance type variable.
    Return None if not found.
    """
    instance_cmd = "/usr/bin/curl -s http://169.254.169.254/latest/meta-data/{}".format(instance_type)
    print("\nRunning instance command: " + instance_cmd, file=open(LOG_FILE, 'a'))
    proc = subprocess.run(instance_cmd, shell=True, capture_output=True)
    log_proc_output(proc)

    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8")


def on_init():
    """
    Some initial checks. Exit if fails.
    """
    current_time = datetime.now().strftime(TIME_FORMAT)
    print(current_time + ": Starting execution of " + CURRENT_SCRIPT + " (version: " + SCRIPT_VERSION + ")",
          file=open(LOG_FILE, 'a'))

    print("Performing initial checks...", file=open(LOG_FILE, 'a'))
    if get_instance_value("instance-id") is None:
        on_exit("Unable to locate local instance-id.")

    if config['general']['instance.name'] != '':
        log.info("Using instance name '" + config['general']['instance.name'] + "' from config file.")

    # Verify Nvidia GPU is available.
    check_cmd = "/usr/bin/lspci | /usr/bin/grep -i nvidia"
    print("\nRunning GPU check command: " + check_cmd, file=open(LOG_FILE, 'a'))
    proc = subprocess.run(check_cmd, shell=True, capture_output=True)
    log_proc_output(proc)
    if proc.returncode != 0:
        on_exit("No Nvidia GPU found on this VM. Cannot continue with setup.")

    smi_cmd = "/usr/bin/nvidia-smi"
    print("\nRunning Nvidia SMI command: " + smi_cmd, file=open(LOG_FILE, 'a'))
    proc = subprocess.run(smi_cmd, shell=True, capture_output=True)
    log_proc_output(proc)
    if proc.returncode != 0:
        on_exit("No Nvidia 'nvidia-smi' (Nvidia System Mgmt. Interface) found on this VM. Cannot continue with setup.")

    dcgmi_cmd = "/usr/bin/dcgmi discovery -l"
    print("\nRunning DCGMI check command: " + dcgmi_cmd, file=open(LOG_FILE, 'a'))
    proc = subprocess.run(dcgmi_cmd, shell=True, capture_output=True)
    log_proc_output(proc)
    if proc.returncode != 0:
        on_exit("No Nvidia 'dcgmi' (DCGM Interface) found on this VM. Cannot continue with setup.")

    run_user = config['general']['run.user']
    if run_user == '':
        on_exit('User to run CloudWatch agent as is not specified in config file.')

    if os.getlogin() == 'root':
        on_exit("Please run script as non-root user, e.g. 'ubuntu'.")
    print("Initial checks completed.", file=open(LOG_FILE, 'a'))

    if not os.path.exists("/usr/bin/docker"):
        on_exit("Docker not found. Required for DCGM setup.")


def on_exit(exit_message=None):
    """
    Called on exit.
    """
    current_time = datetime.now().strftime(TIME_FORMAT)
    print(current_time + ": Completed execution of " + CURRENT_SCRIPT, file=open(LOG_FILE, 'a'))

    if exit_message is not None:
        exit(exit_message)

    exit(0)


def setup_nvidia_dcgm():
    """
    Performs steps needed for getting Nvidia DCGM metrics.
    """

    docker_setup_dcgm_exporter()
    write_prometheus_yaml()
    configure_agent(CWAGENT_CONFIG_NVIDIA_DCGM)

    # Log initial metrics, may not be ready yet, but try anyway.
    print("Logging initial Prometheus metrics from metric endpoint...", file=open(LOG_FILE, 'a'))
    metric_cmd = "/usr/bin/curl localhost:" + config['dcgm-exporter']['prometheus.port'] \
                 + "/metrics | /usr/bin/grep -v '#'"
    proc = subprocess.run(metric_cmd, shell=True, capture_output=True)
    log_proc_output(proc)


def setup_required(target_status, current_status):
    """
    What setup is required to achieve the target setup status.
    E.g. do the base config if current status is 'not configured' (i.e. a clean system).
    """
    if target_status == AgentConfigStatus.CONFIGURED_BASE_METRICS:
        return current_status == AgentConfigStatus.NOT_CONFIGURED

    if target_status == AgentConfigStatus.CONFIGURED_NVIDIA_SMI_METRICS:
        return current_status == AgentConfigStatus.NOT_CONFIGURED or \
               current_status == AgentConfigStatus.CONFIGURED_BASE_METRICS

    if target_status == AgentConfigStatus.CONFIGURED_NVIDIA_DCGM_METRICS:
        return current_status == AgentConfigStatus.NOT_CONFIGURED or \
               current_status == AgentConfigStatus.CONFIGURED_BASE_METRICS or \
               current_status == AgentConfigStatus.CONFIGURED_NVIDIA_SMI_METRICS

    return False


def ask_confirmation():
    if config['general']['instance.name'] == '':
        log.warning("Instance name is NOT specified in config file '" + CONFIG_FILE
                    + "' property 'general' -> 'instance.name'.")

    sys.stdout.write("""
NOTE: Please confirm that the following PREREQUISITES have been completed before proceeding:
1. This EC2 instance has an attached IAM role with CloudWatch access.
2. CloudWatch agent package has been installed. CloudWatch configuration will be done by this script.
3. This EC2 instance has Nvidia GPUs attached, and already has 'dcgmi' and 'nvidia-smi' CLI tools.
4. If EC2 instance has a name, it is recommended to specify the name in property 'general' -> 'instance.name' of {} config file.
    \n""".format(CONFIG_FILE))
    sys.stdout.write("Configuring DCGM Exporter on this VM. Metrics will be sent to CloudWatch. Continue? [y|n]: ")
    choice = input().lower()
    if choice != 'y':
        on_exit()


if __name__ == '__main__':
    file_handler = logging.FileHandler(filename=LOG_FILE)
    stdout_handler = logging.StreamHandler(stream=sys.stdout)
    handlers = [file_handler, stdout_handler]

    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] %(levelname)s - %(message)s',
        handlers=handlers
    )

    log = logging.getLogger()

    if not os.path.exists(CONFIG_FILE):
        exit("Could not find config file: %s" % CONFIG_FILE)

    config = configparser.ConfigParser()
    config.optionxform = lambda option: option
    config.read(CONFIG_FILE)

    on_init()

    config_status_glob, runtime_status_glob = check_cloudwatch_agent()

    if config_status_glob == AgentConfigStatus.CONFIGURED_NVIDIA_DCGM_METRICS and \
            runtime_status_glob == AgentRuntimeStatus.RUNNING:
        log.info("CloudWatch agent is setup and running already. No changes required.")
        on_exit()

    ask_confirmation()

    # Stop agent first before configuration.
    start_stop_agent('stop')

    # Do base config if needed.
    if setup_required(AgentConfigStatus.CONFIGURED_BASE_METRICS, config_status_glob):
        log.info("Performing base CloudWatch agent configuration...")
        configure_agent(CWAGENT_CONFIG_BASE)

    # Do SMI config if needed.
    if setup_required(AgentConfigStatus.CONFIGURED_NVIDIA_SMI_METRICS, config_status_glob):
        log.info("Performing Nvidia SMI CloudWatch agent configuration...")
        configure_agent(CWAGENT_CONFIG_NVIDIA_SMI)

    # Do DCGM config.
    if setup_required(AgentConfigStatus.CONFIGURED_NVIDIA_DCGM_METRICS, config_status_glob):
        log.info("Performing Nvidia DCGM CloudWatch agent configuration...")
        setup_nvidia_dcgm()

    # Start the agent back.
    start_stop_agent('start')

    log.info("Finally, getting current CloudWatch agent status...")
    config_status_glob, runtime_status_glob = get_agent_status()
    log.info("Config status: " + config_status_glob.name + ". Runtime status: " + runtime_status_glob.name)

    on_exit()
