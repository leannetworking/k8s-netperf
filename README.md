# Network Performance Measurement for Kubernetes

This is simple network performance measurement tool for Kubernetes. We creted it, since the original netperf tool at https://github.com/kubernetes/perf-tests/tree/master/network/benchmarks/netperf was not working.

For using it simply do `kubectl apply -f k8s-netperf.yaml`. This will launch various containers in your Kubernetes cluster:
- a daemon set with host networking to test host-host network performance
- a deamon set attached by the CNI network plugin to test it's performance
- two other PODs so that you will have two nodes with multiple PODs to test intranode performance

Once the PODs are running simply run: `perl runNetPerfTest.pl 2>>log.txt`.

The Perl script has a dependency to the JSON::Parse library, which you can install by `sudo cpan JSON::Parse`. This install also recquires `make` so if you are using a cloud image you also need to install it by `sudo apt install build-essentials`.
