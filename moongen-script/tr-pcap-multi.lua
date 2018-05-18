--- Replay a pcap file and measure throughput...

-- Traffic generator for vBNG demo to be presented at ACM SIGCOMM 2018
--
-- Copyright (C) 2018 by its authors (See AUTHORS)
--
-- This program is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation, either version 3 of the
-- License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful, but
-- WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
-- General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <http://www.gnu.org/licenses/>.

local ffi = require "ffi"

local mg      = require "moongen"
local device  = require "device"
local memory  = require "memory"
local stats   = require "stats"
local log     = require "log"
local pcap    = require "pcap"
local hist    = require "histogram"
local ts      = require "timestamping"
local timer   = require "timer"
local dpdk       = require "dpdk"

local reset_meas = false
local status_mg = 0

function configure(parser)
   parser:description("Replay a PCAP file with rate control and measure latencies.")
   parser:argument("txDev", "txport[:numcores]"):default(0)
   parser:argument("rxDev", "rxport"):default(1):convert(tonumber)
   parser:argument("file", "pcap file"):args(1)
   parser:option("--rate-limit", "replay speed [Mbit/s]\ndefault, 0: replay as fast as possible\n(Relies on hw rate limiting of txDev: see test-setRate.lua)"):default(0):convert(tonumber):target("rateLimit")
   parser:option("-h --hfile", "latency histogram."):default("histogram.csv")
   parser:option("-r --runtime", "running time in seconds."):default(0):convert(tonumber)
   parser:flag("-l --loop", "repeat pcap file")
   parser:flag("-t --timestamps", "add timestamps to a pcap stream to measure latency")
   parser:option("-o --ofile", "file prefix to use for saving the results\n"
                 .. "($prefix.throughput.csv and $prefix.latency.csv)"):default(nil)
   local args = parser:parse()
   return args
end

function pcapfile_list(configfile)
   local file = io.open(configfile, "r");
   local arr = {}
   local cnt = 0
   for line in file:lines() do
	arr[cnt] = line
        cnt = cnt + 1
   end 
   return arr
end

function pcap_list(pcapfiles)
   local res = {}
   for key,value in pairs(pcapfiles) do
       res[key] = pcap:newReader(value)
   end
   return res
end

function master(args)
   local txport, cores
   if args.txDev:find(":") then
      txport, cores = tonumberall(args.txDev:match("(%d+):(%d+)"))
   else
      txport, cores = tonumber(args.txDev), 1
   end
   local txDev, rxDev, lastRxQue
   if txport ~= args.rxDev then
     txDev = device.config({port = txport, txQueues = cores+1, rxQueues = 2})
     rxDev = device.config({port = args.rxDev, rxQueues = cores+1, txQueues = 2})
     lastRxQue = cores
   else
      txDev = device.config({port = txport,
                             txQueues = cores+1, rxQueues = cores+1})
      rxDev = txDev
      lastRxQue = cores
   end
   device.waitForLinks()
   if args.rateLimit > 0 then
      log:info('Set hw rate-limit of %s to %s Mbit/s', txDev, args.rateLimit)
      txDev:setRate(args.rateLimit)
   end
   for i = 1, cores do
      mg.startTask("replay_pcap", txDev:getTxQueue(i-1),
                   args.file, args.loop)
   end
   --if args.ofile then
   --   stats.startStatsTask{txDevices = {txDev}, rxDevices = {rxDev},
   --                        format="csv", file=args.ofile .. ".throughput.csv"}
   --else
   --   stats.startStatsTask{txDevices = {txDev}, rxDevices = {rxDev},
   --                        format="plain"}
   --end
   mg.startTask("counterSlave", rxDev:getRxQueue(0))
   if args.timestamps then
      mg.startSharedTask("measure_latency", txDev:getTxQueue(cores),
                         rxDev:getRxQueue(lastRxQue), args.hfile,
                         args.file, args.ofile)
   end
   if args.runtime > 0 then
      mg.setRuntime(args.runtime)
   end
   mg.waitForTasks()
end

function replay_pcap(queue, file, loop)
   local mempool = memory:createMemPool(4096)
   local bufs = mempool:bufArray()
   --local pcapFile = pcap:newReader(file)
   local prev = 0
   local linkSpeed = queue.dev:getLinkStatus().speed
   local pcapfiles = pcapfile_list(file)
   local pcaps = pcap_list(pcapfiles)

   while mg.running() do
      for key,value in pairs(pcaps) do
           local pcapFile = value
           log:info("Pcap file changed to %s", pcapfiles[key])
           pktcnt = 0
           while pktcnt < 10000000 do
               local n = pcapFile:read(bufs)
               pktcnt = pktcnt + n
               if n == 0 then
                      pcapFile:reset()
               end
               queue:sendN(bufs, n)
           end
      end

      if not loop then
	break
      end
   end
end

function measure_latency(txQueue, rxQueue, histfile, file, ofile)
   local timestamper = ts:newTimestamper(txQueue, rxQueue, nil, true)
   local hist = hist:new()
   -- local mac_dst = "68:05:ca:30:50:70"

   local mempool = memory:createMemPool(4096)
   local bufs = mempool:bufArray()
   local pcapFile = pcap:newReader(file)

   local n = pcapFile:read(bufs)
   local m = 0
   local size_warning = false

   mg.sleepMillis(1000) -- ensure that the load task is running
   while mg.running() do
      hist:update(timestamper:measureLatency(
        400,
        function(buf)
           m = m + 1
           if m >= n then
              m = 0
           end
           local sample = bufs.array[m]:getEthernetPacket()
           local pkt = buf:getEthernetPacket()
           if true then
              -- pkt.eth.dst:setString(mac_dst)
              pkt.eth:setDst( sample.eth:getDst() )
              pkt.eth:setSrc( sample.eth:getSrc() )

              -- pkt.eth:setType(2048)
              -- print(pkt.eth:getType())

              sample = bufs.array[m]:getIPPacket()
              if sample then
                 pkt = buf:getIPPacket()
                 pkt.ip4.src:set( sample.ip4.src:get() )
                 pkt.ip4.dst:set( sample.ip4.dst:get() )
                 pktSize = sample.ip4:getLength()
                 if pktSize < 76 then
                    pktSize = 76
                    if not size_warning then
                       log:warn('[Timestamping] Packet size increased to 76 bytes')
                       size_warning = true
                    end
                 end

                 -- buf:getUdpPacket().udp:setDstPort(3190)

                 buf:getUdpPtpPacket():setLength(pktSize)
                 buf.data_len = pktSize
              end
           else
              ffi.copy(buf:getData(), bufs.array[m]:getData(), bufs.array[m]:getSize())
              -- buf:getEthernetPacket().eth:setType(35063)
              buf:getUdpPacket().udp:setSrcPort(319)
              buf:getUdpPacket().udp:setDstPort(319)
           end
        end))
   end
   hist:print()
   hist:save(histfile)
   local prefix = 'X'
   log:warn("%sSamples: %d, Average: %.1f ns, StdDev: %.1f ns, Quartiles: %.1f/%.1f/%.1f ns",
            prefix and ("[" .. prefix .. "] ") or "",
            hist.numSamples, hist.avg, hist.stdDev, unpack(hist.quarts))
   if ofile then
      file = io.open(ofile .. ".latency.csv", "w")
      file:write("Samples,Average,StdDev,1st_Quartiles,2nd_Quartiles,3rd_Quartiles\n")
      file:write(string.format("%d,%.1f,%.1f,%.1f,%.1f,%.1f\n",
                               hist.numSamples, hist.avg, hist.stdDev, unpack(hist.quarts)))
      file:close()
   end
end

function counterSlave(queue)
	local bufs = memory.bufArray()
	local ctrs = {}
        local files = {}
        flog = io.open("/tmp/status.mg", "w")
        flog:write(tostring(status_mg))
        flog:close()
	status_mg = status_mg + 1
	log:warn("counterSlave")
	while mg.running() do
		local rx = queue:recv(bufs)
		for i = 1, rx do
			local buf = bufs[i]
			local pkt = buf:getTcpPacket()
			local port = pkt.tcp:getDstPort()
			if port > 2010 then
				log:warn("Unexpected port number %d", port)
				break
			end
			local ctr = ctrs[port]
			if not ctr then
				files[port] = io.open(tostring(port) .. ".th", "w")
				ctr = stats:newPktRxCounter("Port " .. port, "plain", files[port])
				ctrs[port] = ctr
			end
			ctr:countPacket(buf)
--			log:warn("XX")
		end
		-- update() on rxPktCounters must be called to print statistics periodically
		-- this is not done in countPacket() for performance reasons (needs to check timestamps)
		for k, v in pairs(ctrs) do
			v:update()
		end
		bufs:freeAll()
		if reset_meas then
			for k, v in pairs(ctrs) do
				v:finalize()
				flies[k]:close()
				os.remove( tostring(k) .. ".th" )
			end
			ctrs = {}
			files = {}
			reset_meas = false
			flog = io.open("/tmp/status.mg", "w")
			flog:write(tostring(status_mg))
			flog:close()
			status_mg = status_mg + 1
		end
	end
	for k, v in pairs(ctrs) do
		v:finalize()
		files[k]:close()
	end
	-- TODO: check the queue's overflow counter to detect lost packets
end
