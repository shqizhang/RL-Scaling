# rl-signal-sdk

Lightweight Python SDK that lets RL training frameworks signal lifecycle
events (sampling progress, sampling done, batch complete, training done) to
the [RL Scaling Controller](../rl-scaling-controller).

```python
from rl_signal import RLSignalEmitter, BatchMeta

emitter = RLSignalEmitter(controller_url="http://rl-scaling-controller:8080")

emitter.sampling_progress(0.8, BatchMeta(batch_size=128, avg_isl=512))
emitter.sampling_done(BatchMeta(batch_size=128, avg_isl=512))
# ... call Dynamo Frontend /v1/batch/completions ...
emitter.batch_complete()
# ... train ...
emitter.training_done()
```

## Install (editable, dev)

```powershell
pip install -e ".[test]"
pytest -q
```
