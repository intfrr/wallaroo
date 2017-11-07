# Performance Testing Python Market Spread Guide

This is a guide to help you setup an AWS cluster in order to performance test Python Market Spread. This guide includes both [single worker](#single-worker-pony-market-spread) and [two worker](#two-worker-pony-market-spread) guides.

If you have not followed the setup instructions in the `orchestration/terraform` [README](../../../../orchestration/terraform/README.md) please do so before continuing.


## Cluster Start

To start an AWS cluster first change directories from within the main `wallaroo` directory with the following command:

```bash
cd orchestration/terraform
```

Then run the following command to start a 1 machine cluster:

```bash
make cluster cluster_name=<YOUR_CLUSTER_NAME> mem_required=30 cpus_required=36 num_followers=0 force_instance=c4.8xlarge spot_bid_factor=100 ansible_system_cpus=0,18 ansible_isolcpus=true no_spot=true cluster_project_name=wallaroo_perf_testing
```

If successful, you should see output that looks like this:

```bash
PLAY RECAP *********************************************************************
52.3.244.174               : ok=86   changed=54   unreachable=0    failed=0

==> Successfully ran ansible playbook for cluster 'perftest' in region 'us-east-1' at provider 'aws'!
```

You can SSH into the AWS machines using:

```bash
ssh -i ~/.ssh/ec2/us-east-1.pem ubuntu@<IP_ADDRESS>
```

## Build Setup

SSH into the `wallaroo-leader-1` machine and follow the linux set up [instructions](../../../../../book/getting-started/linux-setup.md) up to the `Install Python Development Libraries` section.

Get a copy of the `wallaroo` repo:

```bash
cd ~/
git clone https://github.com/WallarooLabs/wallaroo.git
```
Build the required Wallaroo tools:

```bash
cd ~/wallaroo
make build-machida
make build-giles-sender
make build-giles-receiver
make build-utils-cluster_shutdown
```

## Start Metrics UI

SSH into `wallaroo-leader-1`

Start the Metrics UI:

```bash
docker run -d -u root --cpuset-cpus 0,18 --privileged  -v /usr/bin:/usr/bin:ro   -v /var/run/docker.sock:/var/run/docker.sock -v /bin:/bin:ro  -v /lib:/lib:ro  -v /lib64:/lib64:ro  -v /usr:/usr:ro  -v /tmp:/apps/metrics_reporter_ui/log  -p 0.0.0.0:4000:4000 -p 0.0.0.0:5001:5001 -e "BINS_TYPE=demo" -e "RELX_REPLACE_OS_VARS=true" --name mui -h mui --net=host wallaroolabs/wallaroo-metrics-ui:0.1

```

### Restarting the Metrics UI

If you need to restart the Metrics UI, run the following command on the machine you started the Metrics UI on:

```bash
docker restart mui
```

## Running Single Worker Python Market Spread

### Start Giles Receiver

SSH into `wallaroo-leader-1`

Start Giles Receiver with the following command:

```bash
sudo cset proc -s user -e numactl -- -C 16,17 chrt -f 80 ~/wallaroo/giles/receiver/receiver --ponythreads=1 --ponynoblock --ponypinasio -w -l wallaroo-leader-1:5555
```

### Start the Python Market Spread Application

SSH into `wallaroo-leader-1`

Start the Python Market Spread application with the following command:

```bash
cd ~/wallaroo/testing/performance/apps/python/market_spread

sudo PYTHONPATH="$PYTHONPATH:.:$HOME/wallaroo/machida" cset proc -s user -e numactl -- -C 1,17 chrt -f 80 ~/wallaroo/machida/build/machida --application-module market_spread -i wallaroo-leader-1:7000,wallaroo-leader-1:7001 -o wallaroo-leader-1:5555 -m wallaroo-leader-1:5001 -c wallaroo-leader-1:12500 -d wallaroo-leader-1:12501 -t -e wallaroo-leader-1:5050 --ponythreads=1 --ponypinasio --ponynoblock
```

### Start Giles Senders

SSH into `wallaroo-leader-1`

You can run the following commands individually or in a script, the only sender that must be run to completion before starting any of the others is the Initial NBBO Sender.

#### Initial NBBO Sender

```bash
sudo cset proc -s user -e numactl -- -C 10,17 chrt -f 80 ~/wallaroo/giles/sender/sender -h wallaroo-leader-1:7001 -m 350 -s 90 -i 2_500_000 -f ~/wallaroo/testing/data/market_spread/nbbo/350-symbols_initial-nbbo-fixish.msg --ponythreads=1 -y -g 46 --ponypinasio -w —ponynoblock
```

#### NBBO Sender

```bash
sudo cset proc -s user -e numactl -- -C 11,17 chrt -f 80 ~/wallaroo/giles/sender/sender -h wallaroo-leader-1:7001 -m 10000000000 -s 90 -i 2_500_000 -f ~/wallaroo/testing/data/market_spread/nbbo/350-symbols_nbbo-fixish.msg -r --ponythreads=1 -y -g 46 --ponypinasio -w —ponynoblock
```

#### Orders Sender

```bash
sudo cset proc -s user -e numactl -- -C 12,17 chrt -f 80 ~/wallaroo/giles/sender/sender -h wallaroo-leader-1:7000 -m 5000000000 -s 175 -i 5_000_000 -f ~/wallaroo/testing/data/market_spread/orders/350-symbols_orders-fixish.msg -r --ponythreads=1 -y -g 57 --ponypinasio -w —ponynoblock
```

### Market Spread Cluster Shutdown

When it's time to shutdown your Market Spread cluster, you'd want to do the following.

SSH into `wallaroo-leader-1`

Run the following command to shutdown the cluster:

```bash
sudo cset proc -s user -e numactl -- -C 15,17 chrt -f 80 ~/wallaroo/utils/cluster_shutdown/cluster_shutdown wallaroo-leader-1:5050 --ponythreads=1 --ponynoblock --ponypinasio
```
## Running Two Worker Python Market Spread

### Start Giles Receiver

SSH into `wallaroo-leader-1`

Start Giles Receiver with the following command:

```bash
sudo cset proc -s user -e numactl -- -C 16,17 chrt -f 80 ~/wallaroo/giles/receiver/receiver --ponythreads=1 --ponynoblock --ponypinasio -w -l wallaroo-leader-1:5555
```

### Start the Python Market Spread Application

SSH into `wallaroo-leader-1`

Start the Python Market Spread application Initializer with the following command:

```bash
cd ~/wallaroo/testing/performance/apps/python/market_spread

sudo PYTHONPATH="$PYTHONPATH:.:$HOME/wallaroo/machida" cset proc -s user -e numactl -- -C 1,17 chrt -f 80 ~/wallaroo/machida/build/machida --application-module market_spread -i wallaroo-leader-1:7000,wallaroo-leader-1:7001 -o wallaroo-leader-1:5555 -m wallaroo-leader-1:5001 -c wallaroo-leader-1:12500 -d wallaroo-leader-1:12501 -t -e wallaroo-leader-1:5050 -w 2 --ponythreads=1 --ponypinasio --ponynoblock
```

Start the Python Market Spread application Worker 2 with the following command:

```bash
cd ~/wallaroo/testing/performance/apps/python/market_spread

sudo PYTHONPATH="$PYTHONPATH:.:$HOME/wallaroo/machida" cset proc -s user -e numactl -- -C 2,17 chrt -f 80 ~/wallaroo/machida/build/machida --application-module market_spread -i wallaroo-leader-1:7000,wallaroo-leader-1:7001 -o wallaroo-leader-1:5555 -m wallaroo-leader-1:5001 -c wallaroo-leader-1:12500 -n worker2 --ponythreads=1 --ponypinasio --ponynoblock
```

### Start Giles Senders

SSH into `wallaroo-leader-1`

You can run the following commands individually or in a script, the only sender that must be run to completion before starting any of the others is the Initial NBBO Sender.

#### Initial NBBO Sender

```bash
sudo cset proc -s user -e numactl -- -C 10,17 chrt -f 80 ~/wallaroo/giles/sender/sender -h wallaroo-leader-1:7001 -m 350 -s 50 -i 2_500_000 -f ~/wallaroo/testing/data/market_spread/nbbo/350-symbols_initial-nbbo-fixish.msg --ponythreads=1 -y -g 46 --ponypinasio -w —ponynoblock
```

#### NBBO Sender

```bash
sudo cset proc -s user -e numactl -- -C 11,17 chrt -f 80 ~/wallaroo/giles/sender/sender -h wallaroo-leader-1:7001 -m 10000000000 -s 50 -i 2_500_000 -f ~/wallaroo/testing/data/market_spread/nbbo/350-symbols_nbbo-fixish.msg -r --ponythreads=1 -y -g 46 --ponypinasio -w —ponynoblock
```

#### Orders Sender

```bash
sudo cset proc -s user -e numactl -- -C 12,17 chrt -f 80 ~/wallaroo/giles/sender/sender -h wallaroo-leader-1:7000 -m 5000000000 -s 100 -i 5_000_000 -f ~/wallaroo/testing/data/market_spread/orders/350-symbols_orders-fixish.msg -r --ponythreads=1 -y -g 57 --ponypinasio -w —ponynoblock
```

### Market Spread Cluster Shutdown

When it's time to shutdown your Market Spread cluster, you'd want to do the following.

SSH into `wallaroo-leader-1`

Run the following command to shutdown the cluster:

```bash
sudo cset proc -s user -e numactl -- -C 15,17 chrt -f 80 ~/wallaroo/utils/cluster_shutdown/cluster_shutdown wallaroo-leader-1:5050 --ponythreads=1 --ponynoblock --ponypinasio
```

## AWS Cluster Shutdown

When it's time to shutdown your AWS cluster, you'd want to do the following.

On your local machine, from the `orchestration/terraform` directory, run the following command:

```bash
make destroy cluster_name=<YOUR_CLUSTER_NAME> mem_required=30 cpus_required=36 num_followers=0 force_instance=c4.8xlarge spot_bid_factor=100 ansible_system_cpus=0,18 ansible_isolcpus=true no_spot=true cluster_project_name=wallaroo_perf_testing

```

You should see output similar to the following if your cluster shutdown properly:

```bash
Destroy complete! Resources: 5 destroyed.
==> Successfully ran terraform destroy for cluster 'perftest' in region 'us-east-1' at provider 'aws'!
==> Releasing cluster lock...
aws sdb put-attributes --region us-east-1 --domain-name \
          terraform_locking --item-name aws-us-east-1_lock --attributes \
          Name=perftest-lock,Value=free,Replace=true \
          --expected Name=perftest-lock,Value=`id -u -n`-`hostname`
==> Cluster lock successfully released!
```
