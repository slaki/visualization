import os
from select import select
from influxdb import InfluxDBClient
import datetime
import subprocess
from sys import argv
import re

DBNAME='sigcomm_demo'

DUT_IP='p4@192.168.0.102' # entering by key is needed

client = InfluxDBClient(database=DBNAME)

def get_cpu_dut():
	bashCommand = ["ssh", DUT_IP, "ps aux --sort -%cpu,-rss"]
	cpuusage = 0.0
	try:
		process = subprocess.Popen(bashCommand, stdout=subprocess.PIPE)
		output = process.communicate()[0].split('\n')
		del output[0] ## heading
		del output[-1] ## last empty line
		for i in output:
			cpuusage += float(i.split()[2])
	except Exception as err:
		print "Error", err, " -- ", DUT_IP, i
		cpuusage =  -1.0
	client.write( ['cpuusage,mode=cpu value=%f' % ( cpuusage)], {'db':DBNAME},204,'line')


def check_files(files, files_used):
	new_list = []
	for f in files:
		if f not in files_used:
			new_list.append( f )
	return new_list

def process(fn, fd, t=0):
	data = fd.readline()
	ansi_escape = re.compile(r'\x1B\[[0-?]*[ -/]*[@-~]')
	if not data:
		return
	try:
		parsed = data.split('(')[1].split(' ')
		rate = float(parsed[0])
		did = data.split('=')[1].split(']')[0]
		v = ansi_escape.sub('', data.split(' ')[2])
		if v == "RX:":
			client.write( ['rxrate,mode=rx value=%f' % (rate)], {'db':DBNAME},204,'line')
		elif v == "TX:":
			client.write( ['txrate,mode=tx value=%f' % (rate)], {'db':DBNAME},204,'line')
	except Exception as err:
		print "Error:", err, " -- ", data


files_used = []
files_desc = []
desc_map = {}
filename = "throughput.txt"


if len(argv)>2:
	print "Wrong arguments: %s (<throughputlog file>)" % argv[0]
	exit(-1)
elif len(argv)==2:
	filename = argv[1]


print "InfluxDB loader has been Launched..."
#[f for f in os.listdir('.') if os.path.isfile(f) and f[-3:]==".th"]
try:
	while True:
		files = [filename] #[f for f in os.listdir('.') if os.path.isfile(f) and f[-3:]==".th"]
	
		new_files = check_files(files, files_used)

		for f in new_files:
			fd = open(f, 'r')
			fd.seek(0,2)
			files_desc.append(fd)
			files_used.append(f)
			desc_map[fd] = f.split('.')[0]

		get_cpu_dut()

		readables, _, _ = select(files_desc, [], [], 1.0)
		#t = datetime.datetime.utcnow()
	
		for fd in readables:
			process(desc_map[fd], fd)
			

finally:
	for f in files_desc:
		f.close()
