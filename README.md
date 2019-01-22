# Network Performance Measurement for Kubernetes

This is simple network performance measurement tool for Kubernetes. We created it, since the original Netperf tool at https://github.com/kubernetes/perf-tests/tree/master/network/benchmarks/netperf was not working properly.

For using it simply do `kubectl apply -f k8s-netperf.yaml`. This will launch various containers in your Kubernetes cluster:
- a daemon set with host networking to test host-to-host network performance (which tipically is unaffected by the network plugin)
- a daemon set attached by the CNI network plugin to test it's performance
- two other PODs so that you will have two nodes with multiple PODs to test intranode performance

The Perl program has a dependency to the JSON::Parse library, which you can install by `sudo cpan JSON::Parse`. This install also requires `make` so if you are using a cloud image you also need to install it by `sudo apt install build-essentials`.

Once the PODs are running simply run: `perl runNetPerfTest.pl`
Within the program simple `kubectl` commands are executed and the output is parsed. I know this is a very poor approach, yet it is so simple everyone can understand what is going on.
The row output of the cmd commands will be printed to `STDERR`, so in case you only want to see the measurement results just run `perl runNetPerfTest.pl 2>>log.txt`.

The following scenarios are measured:

| # | Description | Baseline | 
| - | ----------- | -------- |
| 1 | POD running in hostnetworking mode to localhost | Yes | 
| 2 | POD using normal networking to localhost | Yes | 
| 3 | POD using normal networking to its host (the POD running in hostnetworking mode on the same host) | Yes | 
| 4 | Between two PODs (using normal networking) located on the same node | No | 
| 5 | Between two POD in hostnetworking mode (just like the two nodes were running the measurement) | Yes | 
| 6 | Between two PODs (using normal networking) located on different nodes | No | 
| 7 | POD using normal networking to another node (a POD running in hostnetworking mode on another node) | Yes | 
| 8 | POD running in hostnetworking mode to a POD on another node (using normal networking) | Yes | 
| 9 | POD using normal networking to the ClusterIP of the Netperf service | No | 

In all scenarios* the following metrics are measured with the corresponding tools:

| # | Tool | Metrics | Unit |
| - | ---- | ------- | ---- |
| 1 | Iperf | Bulk Throughput | bits / sec | 
| 2 | Netperf in TCP_RR mode | Latency (50,90 and 99 percentiles) and Transaction rate | seconds and transactions / sec | 
| 3 | Netperf in TCP_CRR mode | Transaction rate | transactions / sec | 
| 4 | Fortio using HTTP 1.0 | Latency (50,90 and 99 percentiles) and Transaction rate | seconds and queries / sec | 
| 5 | Fortio using HTTP 1.1 | Latency (50,90 and 99 percentiles) and Transaction rate | seconds and queries / sec | 
| 6 | Fortio using GRPC | Latency (50,90 and 99 percentiles) and Transaction rate | seconds and queries / sec | 

You can use the `--nobaseline` argument to skip the baselane measurements, since baseline measurements tends to have the same result.
Thus run `perl runNetPerfTest.pl --nobaseline 2>>log.txt` to run only scenarios #4, #6 and #9.

*In scenario #9 we don't run Netperf, since you can't connect to it via ClusterIP due to its internal mechanism (and how Kubernetes abstracts services).

