import os
from select import select
from influxdb import InfluxDBClient
import datetime


DBNAME='sigcomm_demo'

print "Connecting to InfluxDB..."
client = InfluxDBClient()

print "Create database:",  DBNAME
client.create_database(DBNAME)

print "Done."
