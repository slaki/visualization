#!/bin/sh

echo "Launching InfluxDB"
docker run -d --name sigcomm_influxdb -p 8083:8083 -p 8086:8086 -p 25826:25826/udp influxdb:1.5

mkdir ~/grafana-sigcomm
chmod 777 ~/grafana-sigcomm

echo "Launching Grafana"
docker run -d --name sigcomm_grafana -v ~/grafana-sigcomm:/var/lib/grafana -p 3000:3000 --link sigcomm_influxdb grafana/grafana

echo "Done."
