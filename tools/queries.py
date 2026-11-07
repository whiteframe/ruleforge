from sigma.collection import SigmaCollection
from sigma.backends.elasticsearch import LuceneBackend
from sigma.pipelines.elasticsearch.windows import ecs_windows
from sigma.pipelines.sysmon import sysmon_pipeline
from sigma.pipelines.windows import windows_logsource_pipeline

PIPELINES = {
    "ecs": ecs_windows,                                                    # Winlogbeat data
    "sysmon": lambda: sysmon_pipeline() + windows_logsource_pipeline(),  # raw field names
}


def lucene(rule_path, fields):
    rules = SigmaCollection.from_yaml(open(rule_path).read())
    return LuceneBackend(PIPELINES[fields]()).convert(rules)[0]
