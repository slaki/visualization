#!/bin/sh


echo "Stop InfluxDB"
docker stop sigcomm_influxdb

echo "Stop Grafana"
docker stop sigcomm_grafana 

echo "Done."
