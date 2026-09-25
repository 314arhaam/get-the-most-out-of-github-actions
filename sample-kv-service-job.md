# Sample structure of KV service

```mermaid
flowchart 
subgraph kv [KV Job]
start_kv[Start Key Value Service]
if_service_up{KV service up?}
to_reached{Timeout reached}
submit_key_val["SET {'main_service': 'kv_service'}"]
if_exists{GET 'main_service'}
sleep5[Sleep 5s]
sleep1[Sleep 1s]
finish[Finish]
echo@{shape: console, label: "echo $(date)"}
start_kv-->if_service_up
if_service_up-->|True|submit_key_val
if_service_up-->|False|to_reached
to_reached-->|True|finish
to_reached-->|False|sleep1
sleep1-->if_service_up
submit_key_val-->if_exists
if_exists-->|Exists|echo-->sleep5-->if_exists
if_exists-->|Not Exists|finish
end
```
