FROM alpine:3.7 as netperfbuild

# Install dependencies for netperf compile
RUN apk add --update --no-cache g++ make curl
	
# Download and install NetPerf
RUN curl -LO https://github.com/HewlettPackard/netperf/archive/netperf-2.7.0.tar.gz \
    && tar -xzf netperf-2.7.0.tar.gz \
    && mv netperf-netperf-2.7.0/ netperf-2.7.0
RUN cd netperf-2.7.0 && ./configure \
    && make && make install

FROM fortio/fortio:1.3.0 as fortiobuild

FROM alpine:3.7
# This is a mixed container of NetPerf and Iperf for Kubernetes network performance testing
MAINTAINER info@leannet.eu

# Intall iperf using apk and clean the cache 
RUN apk add --no-cache iperf 

# Copy netperf binarias from the built image
COPY --from=netperfbuild /usr/local/bin/netperf /usr/local/bin/netperf
COPY --from=netperfbuild /usr/local/bin/netserver /usr/local/bin/netserver

# Copy the fortio binaries and files
COPY --from=fortiobuild /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=fortiobuild /usr/share/fortio/static /usr/share/fortio/static
COPY --from=fortiobuild /usr/share/fortio/templates /usr/share/fortio/templates
COPY --from=fortiobuild /usr/bin/fortio /usr/bin/fortio

# Copy the minimal start scprit
COPY run.sh ./
RUN chmod 744 run.sh

EXPOSE 5001/udp
EXPOSE 5001/tcp
EXPOSE 8079/tcp
EXPOSE 8080/tcp
EXPOSE 8081/tcp
EXPOSE 12865/tcp

ENTRYPOINT ["./run.sh"]
