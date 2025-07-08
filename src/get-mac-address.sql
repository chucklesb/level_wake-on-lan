SELECT id.mac
FROM interface_addresses AS ia
JOIN interface_details AS id
  ON ia.interface = id.interface
WHERE ia.address LIKE '%.%.%.%' AND ia.address NOT LIKE '%:%'
  AND in_cidr_block('{{cf_wake-on-lan_subnet}}', ia.address)
ORDER BY id.metric ASC
LIMIT 1;