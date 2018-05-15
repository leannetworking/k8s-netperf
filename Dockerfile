FROM alpine:3.7
MAINTAINER info@leannet.eu
# This is a mixed container of NetPerf and Iperf for Kubernetes network performance testing

# Install dependencies
RUN apk add --update --no-cache g++ make curl iperf
	
# Download and install NetPerf
RUN curl -LO https://github.com/HewlettPackard/netperf/archive/netperf-2.7.0.tar.gz && tar -xzf netperf-2.7.0.tar.gz && mv netperf-netperf-2.7.0/ netperf-2.7.0
RUN cd netperf-2.7.0 && ./configure && make && make install

# Remove some files to save space
RUN rm -rf /var/cache/apk/*
RUN rm netperf-2.7.0.tar.gz
RUN rm -r netperf-2.7.0/

# Copying the minimal start scprit
COPY run.sh ./
RUN chmod 744 run.sh

EXPOSE 5001/udp
EXPOSE 5001/tcp
EXPOSE 12865/tcp

ENTRYPOINT ["./run.sh"]
