#!/usr/bin/perl -w

###################################################
### This script runs several kubectl commands   ###
### in order to measure the network performance ###
### beetween K8s nodes, pods and services       ###
### in various scenarios.                       ###
###                                             ###
### Recquires JSON::Parse, so install it by:    ###
### sudo perl -MCPAN -e 'install JSON::Parse'   ###
###                                             ###
### If make was not OK, than you also need      ###
### to install make by (e.g. on cloud image)    ### 
### sudo apt install build-essentials           ###
###                                             ###
### Written by Megyo on 15. May 2018            ###
###################################################

use strict;
use JSON::Parse ':all';

#maximum number of measurements in different types
my $numberOfLocalhostMeasurements = 2;
my $numberOfInterNodeMeasurements = 4;
my $iperfTime = 20;

my $netperfRequestPacketSize = 32;
my $netperfResponsePacketSize = 1024;

#hash to store every data on Nodes
my %nodes = ();

#hash to store every data on NetPerf Pods
my %pods = ();

#hash to store every data on Netperf Service
my %services = ();

my $IPregexp = '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}';

#get name of all nodes in the cluster
my $allNodes = `kubectl get nodes -o name`;
foreach (split("\n", $allNodes)) {
    #this will be the temporary variable to store all relevant Node data
    my %tmp = ();
    
    #add array for future POD information
    my @podsOnThisNode = ();
    $tmp{'pods'} = \@podsOnThisNode;
        
    $_ =~ s/node\///;
    print STDERR "Node: $_\n";
    
    #get all the information on this particular Nodes
    my $res = `kubectl describe node $_`;
    foreach my $line (split("\n", $res)) {
        #get IPaddress of the Node
        if ($line =~ /InternalIP:.*?($IPregexp)/) {
            $tmp{'IPaddress'} = $1;
        }
        
        #get PodCIDR of the Node 
        if ($line =~ /PodCIDR:.*?($IPregexp\/\d+)/) {
            $tmp{'PodCIDR'} = $1;
        }
        
    }
    $nodes{$_} = \%tmp;
}


#get name of all pods in the cluster
my $allPods = `kubectl get pods -o=custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace | grep netperf`;
foreach (split("\n", $allPods)) {
    #next if ($_ =~ /NAMESPACE/); #just skip the first header line
    
    #this will be the temporary variable to store all relevant POD data
    my %tmp = ();
    
    my ($name, $namespace) = split(/ +/, $_);
    print STDERR "Pod: $name  in  $namespace \n";
    $tmp{'namespace'} = $namespace;
    
    #get all the information on this particular Nodes
    my $res = `kubectl describe pod $name --namespace=$namespace`;
    foreach my $line (split("\n", $res)) {
        #get IPaddress of the POD
        if ($line =~ /IP:.*?($IPregexp)/) {
            $tmp{'IPaddress'} = $1;
        }
        
        #get the Node that the POD is running on
        if ($line =~ /Node: +(.*?)\/($IPregexp)/) {
            $tmp{'NodeName'} = $1;
            $tmp{'NodeIP'} = $2;            
        }
    }
	#if this POD runs in host mode, we add it to the node
	if ($tmp{'IPaddress'} eq $tmp{'NodeIP'}) {
		$nodes{$tmp{'NodeName'}}->{'HostNetPerf'} = $name;
	}	
	#adding the same POD to the Node's list and to the POD list
	else {
		push @{$nodes{$tmp{'NodeName'}}->{'pods'}}, $name;
		$pods{$name} = \%tmp;
	}	
	
}

#get all info on NetPerf service
my $allServices = `kubectl get services --all-namespaces -o wide | grep netperf`;
foreach (split("\n", $allServices)) {
    next if ($_ =~ /NAMESPACE/); #just skip the first header line
    
    #this will be the temporary variable to store all relevant POD data
    my %tmp = ();
    
    my @podBackends = ();
    
    my ($namespace, $name, $type, $clusterIP, $externalIP, $port, $age, $selector) = split(/ +/, $_);
    print STDERR "service: $name  in  $namespace IP=$clusterIP $externalIP $selector \n";
    $tmp{'namespace'} = $namespace;
    $tmp{'type'} = $type;
    $tmp{'clusterIP'} = $clusterIP;
    $tmp{'externalIP'} = $externalIP;
    $tmp{'selector'} = $selector;
    
    
    #get all the POD backends for this service
    my $res = `kubectl get pods -l $selector --all-namespaces -o name`;
    foreach my $line (split("\n", $res)) {
        $line =~ s/pods\///;
        push @podBackends, $line;
    }
    $tmp{'podBackends'} = \@podBackends;
        
    $services{$name} = \%tmp;
}

#in order to get all the ports for the services we do a query in JSON
my $json = `kubectl get services --all-namespaces -o json`;
my $hash = parse_json ($json);
#print ref $hash, "\n";

foreach my $svc (@{$hash->{'items'}}) {
    #print $svc->{'metadata'}->{'name'}, '   ', $svc->{'spec'}->{'ports'}, "\n";
	next unless (defined($services{$svc->{'metadata'}->{'name'}}));
    $services{$svc->{'metadata'}->{'name'}}->{'ports'} = $svc->{'spec'}->{'ports'};
}

print STDERR join(' ',%nodes),"\n";
print STDERR join(' ',%pods),"\n";
print STDERR join(' ',%services),"\n";

#run Iperf on ceratain nodes as localhost
my @randArray = randomKeysFromHash($numberOfLocalhostMeasurements,%nodes);
foreach my $node (@randArray) {
    #run Iperf for throughput measurement
	print STDERR "running command: kubectl exec -it $nodes{$node}->{HostNetPerf} -- iperf -c $nodes{$node}->{IPaddress} -i 1 -t $iperfTime \n";
	open(IPERF, "kubectl exec -it $nodes{$node}->{HostNetPerf} -- iperf -c $nodes{$node}->{IPaddress} -i 1 -t $iperfTime | ");
	my $lastLine = '';
	while (<IPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(IPERF);
	$lastLine =~ s/.*?(\d+\.\d+ .bits\/sec).*/$1/;
	print "Localhost throughput on Node $node: $lastLine\n"; 

	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $nodes{$node}->{HostNetPerf} -- netperf -H $nodes{$node}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $nodes{$node}->{HostNetPerf} -- netperf -H $nodes{$node}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_RR test on Node $node (lantency 50,90 and 99 percentiles in us and DB like transaction rate): $lastLine\n"; 


	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $nodes{$node}->{HostNetPerf} -- netperf -H $nodes{$node}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $nodes{$node}->{HostNetPerf} -- netperf -H $nodes{$node}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_CRR test on Node $node (HTTP API like transaction rate): $lastLine\n"; 
}

#run Iperf on ceratain PODs as localhost
@randArray = randomKeysFromHash($numberOfLocalhostMeasurements,%pods);
foreach my $pod (@randArray) {
	#run Iperf for throughput measurement
    print STDERR "running command: kubectl exec -it $pod -- iperf -c $pods{$pod}->{IPaddress} -i 1 -t $iperfTime \n";
	open(IPERF, "kubectl exec -it $pod -- iperf -c $pods{$pod}->{IPaddress} -i 1 -t $iperfTime | ");
	my $lastLine = '';
	while (<IPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(IPERF);
	$lastLine =~ s/.*?(\d+\.\d+ .bits\/sec).*/$1/;
	print "Localhost throughput on POD $pod: $lastLine\n"; 

	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$pod}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$pod}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_RR test on POD $pod (lantency 50,90 and 99 percentiles in us and DB like transaction rate): $lastLine\n"; 


	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$pod}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$pod}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_CRR test on POD $pod (HTTP API like transaction rate): $lastLine\n"; 

}

#run Iperf on ceratain PODs and their host (use the same random POD array to the previous case)
foreach my $pod (@randArray) {
    print STDERR "running command: kubectl exec -it $pod -- iperf -c $pods{$pod}->{NodeIP} -i 1 -t $iperfTime \n";
	open(IPERF, "kubectl exec -it $pod -- iperf -c $pods{$pod}->{NodeIP} -i 1 -t $iperfTime | ");
	my $lastLine = '';
	while (<IPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(IPERF);
	$lastLine =~ s/.*?(\d+\.\d+ .bits\/sec).*/$1/;
	print "Localhost throughput between POD $pod and it's Node: $pods{$pod}->{NodeName}: $lastLine\n"; 

	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$pod}->{NodeIP} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$pod}->{NodeIP} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_RR test between POD $pod and it's Node: $pods{$pod}->{NodeName} (lantency 50,90 and 99 percentiles in us and DB like transaction rate): $lastLine\n"; 


	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$pod}->{NodeIP} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$pod}->{NodeIP} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_CRR test between POD $pod and it's Node: $pods{$pod}->{NodeName} (HTTP API like transaction rate): $lastLine\n"; 

}

#run Iperf on PODs located on the same host
my %randHash = randomPodPairsOnSameNode($numberOfLocalhostMeasurements);
foreach my $pod (keys %randHash) {
	print STDERR "running command: kubectl exec -it $pod -- iperf -c $pods{$randHash{$pod}}->{IPaddress} -i 1 -t $iperfTime \n";
    open(IPERF, "kubectl exec -it $pod -- iperf -c $pods{$randHash{$pod}}->{IPaddress} -i 1 -t $iperfTime | ");
	my $lastLine = '';
	while (<IPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(IPERF);
	$lastLine =~ s/.*?(\d+\.\d+ .bits\/sec).*/$1/;
	print "Localhost throughput between POD $pod and POD $randHash{$pod} (both located on Node: $pods{$pod}->{NodeName}): $lastLine\n"; 

	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_RR test between POD $pod and POD $randHash{$pod} (lantency 50,90 and 99 percentiles in us and DB like transaction rate): $lastLine\n"; 


	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_CRR test between POD $pod and POD $randHash{$pod} (HTTP API like transaction rate): $lastLine\n"; 

}

#if only have one node, than exit
exit if (scalar(keys %nodes) < 2);

#run Iperf between Nodes to see maximum internode capacity
my %randNodePairs = randomNodePairs($numberOfInterNodeMeasurements);
foreach my $node (keys %randNodePairs) {
	print STDERR "running command: kubectl exec -it $nodes{$node}->{HostNetPerf} -- iperf -c $nodes{$randNodePairs{$node}}->{IPaddress} -i 1 -t $iperfTime \n";
    open(IPERF, "kubectl exec -it $nodes{$node}->{HostNetPerf} -- iperf -c $nodes{$randNodePairs{$node}}->{IPaddress} -i 1 -t $iperfTime | ");
	my $lastLine = '';
	while (<IPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(IPERF);
	$lastLine =~ s/.*?(\d+\.\d+ .bits\/sec).*/$1/;
	print "InterNode throughput between Node $node and Node $randNodePairs{$node}: $lastLine\n"; 

	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $nodes{$node}->{HostNetPerf} -- netperf -H $nodes{$randNodePairs{$node}}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $nodes{$node}->{HostNetPerf} -- netperf -H $nodes{$randNodePairs{$node}}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_RR test between Node $node and Node $randNodePairs{$node} (lantency 50,90 and 99 percentiles in us and DB like transaction rate): $lastLine\n"; 


	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $nodes{$node}->{HostNetPerf} -- netperf -H $nodes{$randNodePairs{$node}}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $nodes{$node}->{HostNetPerf} -- netperf -H $nodes{$randNodePairs{$node}}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_CRR test between Node $node and Node $randNodePairs{$node} (HTTP API like transaction rate): $lastLine\n"; 

}

#run Iperf between PODs running on differnet nodes to see performance degradation
%randHash = randomPodsOnDiffernetNodes(%randNodePairs);
foreach my $pod (keys %randHash) {
    print STDERR "running command: kubectl exec -it $pod -- iperf -c $pods{$randHash{$pod}}->{IPaddress} -i 1 -t $iperfTime \n";
	open(IPERF, "kubectl exec -it $pod -- iperf -c $pods{$randHash{$pod}}->{IPaddress} -i 1 -t $iperfTime | ");
	my $lastLine = '';
	while (<IPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(IPERF);
	$lastLine =~ s/.*?(\d+\.\d+ .bits\/sec).*/$1/;
	print "InterNode throughput between POD $pod (running on Node $pods{$pod}->{NodeName}) and POD $randHash{$pod} (running on Node $pods{$randHash{$pod}}->{NodeName}): $lastLine\n"; 

	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_RR test between POD $pod and POD $randHash{$pod} (lantency 50,90 and 99 percentiles in us and DB like transaction rate): $lastLine\n"; 


	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_CRR test between POD $pod and POD $randHash{$pod} (HTTP API like transaction rate): $lastLine\n"; 

}

#run Iperf between a POD and another node (not the host of the POD)
foreach my $pod (keys %randHash) {
    print STDERR "running command: kubectl exec -it $pod -- iperf -c $pods{$randHash{$pod}}->{NodeIP} -i 1 -t $iperfTime \n";
	open(IPERF, "kubectl exec -it $pod -- iperf -c $pods{$randHash{$pod}}->{NodeIP} -i 1 -t $iperfTime | ");
	my $lastLine = '';
	while (<IPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(IPERF);
	$lastLine =~ s/.*?(\d+\.\d+ .bits\/sec).*/$1/;
	print "InterNode throughput between POD $pod (running on Node $pods{$pod}->{NodeName}) and Node $pods{$randHash{$pod}}->{NodeName}: $lastLine\n"; 

	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{NodeIP} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{NodeIP} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_RR test between POD $pod and Node $pods{$randHash{$pod}}->{NodeName} (lantency 50,90 and 99 percentiles in us and DB like transaction rate): $lastLine\n"; 


	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{NodeIP} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $pod -- netperf -H $pods{$randHash{$pod}}->{NodeIP} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_CRR test between POD $pod and Node $pods{$randHash{$pod}}->{NodeName} (HTTP API like transaction rate): $lastLine\n"; 

}

#run Iperf a node and a POD located on a different node to see difference between asymetric routes
foreach my $pod (keys %randHash) {
    print STDERR "running command: kubectl exec -it $nodes{$pods{$randHash{$pod}}->{NodeName}}->{HostNetPerf} -- iperf -c $pods{$pod}->{IPaddress} -i 1 -t $iperfTime \n";
	open(IPERF, "kubectl exec -it $nodes{$pods{$randHash{$pod}}->{NodeName}}->{HostNetPerf} -- iperf -c $pods{$pod}->{IPaddress} -i 1 -t $iperfTime | ");
	my $lastLine = '';
	while (<IPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(IPERF);
	$lastLine =~ s/.*?(\d+\.\d+ .bits\/sec).*/$1/;
	print "InterNode throughput between Node $pods{$randHash{$pod}}->{NodeName} and POD $pod (running on Node $pods{$pod}->{NodeName}): $lastLine\n"; 

	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $nodes{$pods{$randHash{$pod}}->{NodeName}}->{HostNetPerf} -- netperf -H $pods{$pod}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $nodes{$pods{$randHash{$pod}}->{NodeName}}->{HostNetPerf} -- netperf -H $pods{$pod}->{IPaddress} -l $iperfTime -P 1 -t TCP_RR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o P50_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_RR test between Node $pods{$randHash{$pod}}->{NodeName} and POD $pod (lantency 50,90 and 99 percentiles in us and DB like transaction rate): $lastLine\n"; 


	#run NetPert TCP_RR for latency and database like transaction measurement
    print STDERR "running command: kubectl exec -it $nodes{$pods{$randHash{$pod}}->{NodeName}}->{HostNetPerf} -- netperf -H $pods{$pod}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS \n";
	open(NETPERF, "kubectl exec -it $nodes{$pods{$randHash{$pod}}->{NodeName}}->{HostNetPerf} -- netperf -H $pods{$pod}->{IPaddress} -l $iperfTime -P 1 -t TCP_CRR -- -r $netperfRequestPacketSize,$netperfResponsePacketSize -o THROUGHPUT,THROUGHPUT_UNITS | ");
	while (<NETPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(NETPERF);
	print "Localhost NetPerf TCP_CRR test between Node $pods{$randHash{$pod}}->{NodeName} and POD $pod (HTTP API like transaction rate): $lastLine\n"; 

}

#run Iperf between PODs and Service IP to see kube-proxy performance
#we dont't run NetPerf since its using dinamically allocated port numebers for data exchange, which is not supported in Kubernetes Services abstraction
my $serviceIP = $services{'netperf-server'}->{'clusterIP'};
foreach my $pod (keys %randHash) {
    print STDERR "running command: kubectl exec -it $pod -- iperf -c $serviceIP -i 1 -t $iperfTime \n";
	open(IPERF, "kubectl exec -it $pod -- iperf -c $serviceIP -i 1 -t $iperfTime | ");
	my $lastLine = '';
	while (<IPERF>) {
		print STDERR $_;
		$lastLine = $_;
	}
	close(IPERF);
	$lastLine =~ s/.*?(\d+\.\d+ .bits\/sec).*/$1/;
	print "InterNode throughput between POD $pod and netperf-server service with IP $serviceIP: $lastLine\n"; 
}

sub randomKeysFromHash {
    my $number = shift;
    my %hash = @_; 
    my @randomList = ();
	
    while (($number > 0) and (scalar(keys %hash) > 0)) {
		my $randKey = (keys %hash)[rand keys %hash];
		push @randomList, $randKey;
		delete $hash{$randKey};
		$number--;
	}
	
    return @randomList;
}

sub randomPodPairsOnSameNode {
    my $number = shift;
    my %hash = (); 
    
    foreach my $node (keys %nodes) {
		my @tmp = @{$nodes{$node}->{'pods'}};
		while (($number > 0) and (scalar(@tmp) > 1)) {
			$hash{$tmp[0]} = $tmp[1];
            #print "\t\t$tmp->[0] ---> $tmp->[1]\n";
			shift @tmp;
			$number--;
		}
	}
		
    return %hash;
}

sub randomNodePairs {
    my $number = shift;
    my %hash = (); 
    
	my @tmp = keys %nodes;
	
    return %hash if (scalar(@tmp) < 2);
	
	if (scalar(@tmp) == 2) {
		$hash{$tmp[0]} = $tmp[1];
		$hash{$tmp[1]} = $tmp[0];
		return %hash;
	}

	if (scalar(@tmp) == 3) {
		$hash{$tmp[0]} = $tmp[1];
		$hash{$tmp[1]} = $tmp[0];
		$hash{$tmp[1]} = $tmp[2];
		$hash{$tmp[0]} = $tmp[2];
		return %hash;
	}
	
	if (scalar(@tmp) == 4) {
		$hash{$tmp[0]} = $tmp[1];
		$hash{$tmp[0]} = $tmp[2];
		$hash{$tmp[0]} = $tmp[3];
		$hash{$tmp[1]} = $tmp[2];
		$hash{$tmp[2]} = $tmp[3];
		return %hash;
	}

	while (($number > 0) and (scalar(@tmp) > 1)) {
		$hash{$tmp[0]} = $tmp[1];
		shift @tmp;
		$number--;
	}
		
    return %hash;
}


sub randomPodsOnDiffernetNodes {
    my %nodePairs = @_;
    my %hash = ();

	foreach my $nodeA (keys %nodePairs) {
		my @tmpA = @{$nodes{$nodeA}->{'pods'}};
		my @tmpB = @{$nodes{$nodePairs{$nodeA}}->{'pods'}};
		
		my $podA = $tmpA[rand @tmpA];
		my $podB = $tmpB[rand @tmpB];
		$hash{$podA} = $podB;
	}

	return %hash;
}