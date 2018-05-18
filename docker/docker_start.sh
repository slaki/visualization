#!/bin/sh

echo "Starting InfluxDB"
docker start sigcomm_influxdb

echo "Starting Grafana"
docker start sigcomm_grafana

echo "Done."
