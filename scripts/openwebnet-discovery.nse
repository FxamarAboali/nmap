local stdnse = require "stdnse"
local shortport = require "shortport"
local comm = require "comm"
local string = require "string"

description = [[
OpenWebNet is a communications protocol developed by Bticino since 2000.
Retrieves device identifying information and number of connected devices.

References:
* https://www.myopen-legrandgroup.com/solution-gallery/openwebnet/
* http://www.pimyhome.org/wiki/index.php/OWN_OpenWebNet_Language_Reference
]]

---
-- @usage
-- nmap --script openwebnet-discovery
--
-- @output
--  | openwebnet-discover:
--  |   IP Address: 192.168.200.35
--  |   Net Mask: 255.255.255.0
--  |   MAC Address: 0:3:50:1:d3:11
--  |   Device Type: F453AV
--  |   Firmware Version: 3.0.14
--  |   Uptime: 12d9h42m1s
--  |   Kernel Version: 2.3.8
--  |   Distribution Version: 3.0.1
--  |   Date: 02.07.2017
--  |   Time: 02:11:58
--  |   Scenarios: 0
--  |   Lighting: 115
--  |   Automation: 15
--  |   Power Management: 0
--  |   Heating: 0
--  |   Burglar Alarm: 12
--  |_  Door Entry System: 0

author = "Rewanth Cool"
license = "Same as Nmap--See https://nmap.org/book/man-legal.html"
categories = {"discovery", "safe"}

portrule = shortport.port_or_service(20000, "openwebnet")

local device = {
  [2] = "MHServer",
  [4] = "MH200",
  [6] = "F452",
  [7] = "F452V",
  [11] = "MHServer2",
  [12] = "F453AV",
  [13] = "H4684",
  [15] = "F427 (Gateway Open-KNX)",
  [16] = "F453",
  [23] = "H4684",
  [27] = "L4686SDK",
  [44] = "MH200N",
  [51] = "F454",
  [200] = "F454 (new?)"
}

local who = {
  [0] = "Scenarios",
  [1] = "Lighting",
  [2] = "Automation",
  [3] = "Power Management",
  [4] = "Heating",
  [5] = "Burglar Alarm",
  [6] = "Door Entry System",
  [7] = "Multimedia",
  [9] = "Auxiliary",
  [13] = "Device Communication",
  [14] = "Light+shutters actuators lock",
  [15] = "CEN",
  [16] = "Sound System",
  [17] = "Scenario Programming",
  [18] = "Energy Management",
  [24] = "Lighting Management",
  [25] = "CEN plus",
  [1000] = "Diagnostic",
  [1001] = "Automation Diagnostic",
  [1004] = "Heating Diagnostic",
  [1008] = "Door Entry System Diagnostic",
  [1013] = "Device Diagnostic"
}

local device_dimension = {
  ["Time"] = "0",
  ["Date"] = "1",
  ["IP Address"] = "10",
  ["Net Mask"] = "11",
  ["MAC Address"] = "12",
  ["Device Type"] = "15",
  ["Firmware Version"] = "16",
  ["Hardware Version"] = "17",
  ["Uptime"] = "19",
  ["Micro Version"] = "20",
  ["Date and Time"] = "22",
  ["Kernel Version"] = "23",
  ["Distribution Version"] = "24",
  ["Gateway IP address"] = "50",
  ["DNS IP address 1"] = "51",
  ["DNS IP address 2"] = "52"
}

local ACK = "*#*1##"
local NACK = "*#*0##"

-- Initiates a socket connection
-- Returns the socket and error message
local function get_socket(host, port, request)

  local sd, response, early_resp = comm.opencon(host, port, request)

  if sd == nil then
    return nil, "Socket connection error."
  end

  if not response then
    return nil, "Poor internet connection or no response."
  end

  if response == NACK then
    return nil, "Received a negative ACK as response."
  end

  return sd, nil
end

local function get_response(sd, request)

  local res = {}
  local status, data

  sd:send(request)

  repeat
    status, data = sd:receive_buf("##", true)
    if status and data ~= ACK then
      table.insert(res, data)
    end
    if data == ACK then
      break
    end

    -- If response is NACK, it means the request method is not supported
    if data == NACK then
      res = {}
    end
  until not status

  return res
end

local function format_dimensions(res)

  if res["Date and Time"] then
    res["Date"] = string.match(res["Date and Time"], "((%d+)%.(%d+)%.(%d+))$")

    res["Time"] = string.match(res["Date and Time"], "^((%d+)%.(%d+)%.(%d+))")
    res["Time"] = string.gsub(res["Time"], "%.", ":")

    res["Date and Time"] = nil
  end

  if res["Device Type"] then
    res["Device Type"] = device[ tonumber( res["Device Type"] ) ]
  end

  if res["MAC Address"] then
    res["MAC Address"] = string.gsub(res["MAC Address"], "(%d+)%.", function(num)
      return string.format("%02x:", num)
    end
    )
  end

  if res["Uptime"] then
    local t = {}
    local units = {
      [0] = "d", "h", "m", "s"
    }
    local counter = 0

    for _, v in ipairs(stdnse.strsplit("%.%s*", res["Uptime"])) do
      table.insert(t, v .. units[counter])
      counter = counter + 1
    end

    res["Uptime"] = table.concat(t, "")
  end

  return res

end

action = function(host, port)

  local output = stdnse.output_table()

  local sd, err = get_socket(host, port, ACK)

  -- Socket connection creation failed
  if sd == nil then
    return err
  end

  -- Fetching list of dimensions of a device
  for _, device in ipairs({"IP Address", "Net Mask", "MAC Address", "Device Type", "Firmware Version", "Uptime", "Date and Time", "Kernel Version", "Distribution Version"}) do

    local head = "*#13**"
    local tail = "##"

    stdnse.debug("Fetching " .. device)

    local res = get_response(sd, head .. device_dimension[device] .. tail)

    -- Extracts substring from the result
    -- Ex:
    --  Request - *#13**16##
    --  Response - *#13**16*3*0*14##
    --  Trimmed Output - 3*0*14

    local regex = string.gsub(head, "*", "%%*") .. device_dimension[device] .. "%*" .."(.+)" .. tail
    local tempRes = string.match(res[1], regex)

    output[device] = string.gsub(tempRes, "*", ".")

  end

  -- Format the output based on dimension
  output = format_dimensions(output)

  -- Fetching list of each device
  for i = 0, 6 do

    stdnse.debug("Fetching the list of " .. who[i] .. " devices.")

    local res = get_response(sd, "*#" .. i .. "*0##")
    output[who[i]] = #res

  end

  return output
end
