"""Error taxonomy for the pipeline.

The distinction that matters is not what went wrong but whether trying
again could possibly help. Retrying a permanent error burns the retry
budget, delays the real diagnosis, and -- worst -- turns a clear failure
into a timeout, which reads like an infrastructure problem instead of the
bug it actually is.

So the taxonomy is by REMEDY, not by cause:

    TransientError  a retry could succeed. Object store throttling, a
                    lease not yet released, a solver that needs a
                    different seed. Retry with backoff.
    PermanentError  a retry cannot succeed. Bad input, contract
                    violation, missing credential. Fail now, loudly.
    GateFailure     the stage ran correctly and the result is not fit to
                    use. Distinct from PermanentError because nothing is
                    broken: the pipeline is refusing on purpose, and that
                    refusal is the designed behaviour rather than an
                    incident.

Anything raised that is NOT one of these is treated as permanent. An
unrecognised exception is an unknown failure mode, and retrying an
unknown failure mode is how a pipeline turns a crash into a hang.
"""


class PipelineError(Exception):
    """Base for every error this pipeline raises deliberately."""


class TransientError(PipelineError):
    """Failed, but a retry could plausibly succeed."""


class PermanentError(PipelineError):
    """Failed in a way no retry can fix."""


class GateFailure(PipelineError):
    """Ran correctly; the result did not clear a validation gate.

    Carries the gate name and the observed value so the refusal can be
    reported in terms a reviewer can argue with, rather than as a bare
    traceback.
    """

    def __init__(self, gate: str, detail: str, observed=None):
        super().__init__(f"gate '{gate}' failed: {detail}")
        self.gate = gate
        self.detail = detail
        self.observed = observed
