# cloud-metrics-config

## Overview 

This repo contains some helpful scripts that are used to configure metrics collection for Cloud VMs.
This configuration may be required before IBM Turbonomic can collect metrics from these VMs.


---


## aws-dcgm-exporter

This set of files and the associated script **setup_aws_dcgm_exporter.py**, are used to configure AWS CloudWatch to enable it to collect Nvidia DCGM (Data Center GPU Manager) related metrics.
This script should be run on an AWS VM with Nvidia GPU cards installed.

### What the 'setup_aws_dcgm_exporter.py' script does

This **setup_aws_dcgm_exporter.py** script performs the following metrics configuration steps _incrementally_, when run on an AWS VM with Nvidia GPU cards configured:

1. **Base metrics**:
If `MemoryAvailable` metrics are not currently configured, then sets up CloudWatch to collect this metric, under the _CWAgent_ namespace.

2. **Nvidia SMI metrics**:
If Nvidia SMI metrics are not currently configured, then sets up CloudWatch to collect these metrics related to GPU Count and GPU memory usage, under the _CWAgent_ namespace.

3. **Nvidia DCGM metrics**:
If Nvidia DCGM metrics are not configured, then the script does the following below. These DCGM metrics get written under the AWS _DCGM/GPU_ namespace.
    * Sets up a Docker container with DCGM Exporter image, thus making the DCGM metrics available at the http://localhost:9400/metrics endpoint.
    * Configures CloudWatch to pull DCGM metrics from the above mentioned endpoint.


### Prerequisites before running the 'setup_aws_dcgm_exporter.py' script

Before running the script, please make sure the following prerequisites are met:
1. AWS EC2 instance (VM) in question has a attached IAM role with CloudWatch access.
2. CloudWatch agent package has been installed. CloudWatch configuration will be done by this script.
3. This EC2 instance has Nvidia GPUs attached, and 'nvidia-smi' CLI tool is installed.
4. If EC2 instance has a name, it is recommended to specify the name in property 'general' -> 'instance.name' of aws_dcgm_exporter.cfg config file.
5. `docker` is available on the VM.
6. Script is currently supported on only Ubuntu 20.x or Amazon Linux based AMIs only.


### How to run the 'setup_aws_dcgm_exporter.py' script

1. Setup an Ubuntu GPU VM on an EC2 instance (e.g. g4dn.xlarge) that supports Nvidia GPUs.
2. Install CloudWatch agent package if the package is not already installed. 
3. Create a `aws-dcgm-exporter` sub-directory under the non-root user (e.g. `ubuntu` for an Ubuntu based VM, or `ec2-user` for an Amazon Linux based VM).
4. Copy over all the files from the `aws-dcgm-exporter` directory here, over to this directory `$HOME/aws-dcgm-exporter` on the VM.
5. If EC2 instance has a name, it is recommended to specify the name in property 'general' -> 'instance.name' of aws_dcgm_exporter.cfg config file.
6. Run the `setup_aws_dcgm_exporter.py` script and follow the steps.

_NOTE:_ The path to the `$HOME/aws-dcgm-exporter` directory should not be change in future, once the script has completed running, because the docker container is using the `dcgm_metrics.csv` file there.

### Sample run of the 'setup_aws_dcgm_exporter.py' script

A sample run of the script on an Ubuntu based VM is shown below:
```

ubuntu@ip-172-31-52-137:~/aws-dcgm-exporter$ grep 'instance.name' aws_dcgm_exporter.cfg
instance.name = test-aws-vm

ubuntu@test-aws-vm:~/aws-dcgm-exporter$ chmod +x ./setup_aws_dcgm_exporter.py

ubuntu@ip-172-31-52-137:~/aws-dcgm-exporter$ ./setup_aws_dcgm_exporter.py
[2026-06-12 15:24:39,399] INFO - Using EC2 instance id 'i-051e8f1069944d11d'.
[2026-06-12 15:24:39,399] INFO - Using EC2 instance name 'test-aws-vm' from config file.
[2026-06-12 15:24:41,130] INFO - Getting current CloudWatch agent status...
[2026-06-12 15:24:41,171] INFO - Config status: NOT_CONFIGURED. Runtime status: STOPPED

NOTE: Please confirm that the following PREREQUISITES have been completed before proceeding:
1. This EC2 instance has an attached IAM role with CloudWatch access.
2. CloudWatch agent package has been installed. CloudWatch configuration will be done by this script.
3. This EC2 instance has Nvidia GPUs attached, and 'nvidia-smi' CLI tool is installed..
4. If EC2 instance has a name, it is recommended to specify the name in property 'general' -> 'instance.name' of aws_dcgm_exporter.cfg config file.

Configuring DCGM Exporter on this VM. Metrics will be sent to CloudWatch. Continue? [y|n]: y
[2026-06-12 15:24:43,989] INFO - Stopping CloudWatch agent...
[2026-06-12 15:24:44,018] INFO - Performing base CloudWatch agent configuration...
[2026-06-12 15:24:44,018] INFO - Appending agent config cloudwatch_config_base.json...
[2026-06-12 15:24:44,219] INFO - Performing Nvidia SMI CloudWatch agent configuration...
[2026-06-12 15:24:44,219] INFO - Appending agent config cloudwatch_config_nvidia_smi.json...
[2026-06-12 15:24:44,420] INFO - Performing Nvidia DCGM CloudWatch agent configuration...
[2026-06-12 15:24:44,420] INFO - Checking if DCGM Exporter docker container 'dcgm-exporter' is running...
[2026-06-12 15:24:44,449] INFO - No current DCGM exporter docker container running.
[2026-06-12 15:24:44,449] INFO - Setting up DCGM Exporter docker container (image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04)...
[2026-06-12 15:24:44,450] INFO - Executing docker command:
/usr/bin/sudo /usr/bin/docker rm -f dcgm-exporter; /usr/bin/sudo /usr/bin/docker run --pid=host --privileged -e DCGM_EXPORTER_INTERVAL=60000 --gpus all --restart=always -d -v /proc:/proc -v /home/ubuntu/aws-dcgm-exporter/dcgm_metrics.csv:/etc/dcgm-exporter/default-counters.csv -p 9400:9400 --name dcgm-exporter nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04
Please wait...
[2026-06-12 15:25:17,338] INFO - Successfully setup DCGM Exporter docker container.
[2026-06-12 15:25:17,340] INFO - Writing /opt/aws/amazon-cloudwatch-agent/var/prometheus.yaml file.
[2026-06-12 15:25:17,340] INFO - Current instance-id: i-051e8f1069944d11d, instance name: test-aws-vm
[2026-06-12 15:25:17,351] INFO - Successfully created Prometheus yaml config.
[2026-06-12 15:25:17,351] INFO - Appending agent config cloudwatch_config_nvidia_dcgm.json...
[2026-06-12 15:25:17,693] INFO - Starting CloudWatch agent...
[2026-06-12 15:25:19,113] INFO - Finally, getting current CloudWatch agent status...
[2026-06-12 15:25:19,164] INFO - Config status: CONFIGURED_NVIDIA_DCGM_METRICS. Runtime status: RUNNING
ubuntu@ip-172-31-52-137:~/aws-dcgm-exporter$

```

### Installing CloudWatch agent

AWS CloudWatch agent should be installed on the VM before running the **setup_aws_dcgm_exporter.py** script (please check the other prerequisites above).

Please refer to the AWS documentation on detailed steps on how to install the CloudWatch agent.

For example, on Ubuntu VM:
```
$ cd /tmp
$ wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
$ sudo dpkg -i -E ./amazon-cloudwatch-agent.deb
```

On Amazon Linux:
```
$ sudo yum install amazon-cloudwatch-agent
```

In both cases, the CloudWatch agent gets installed under the `/opt/aws/amazon-cloudwatch-agent/` directory.

Soon after the installation, agent status will show it as _stopped_:
```
$ amazon-cloudwatch-agent-ctl -a status
{
  "status": "stopped",
  "starttime": "",
  "configstatus": "not configured",
  "version": "1.300035.0b547"
}
```

Now follow the instructions above to run the **setup_aws_dcgm_exporter.py** script for the rest of the configuration setup.

---

