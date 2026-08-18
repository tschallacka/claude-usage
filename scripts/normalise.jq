# Normalise the /api/oauth/usage payload into a small flat object.
# Prefers the current limits[] shape; falls back to the older flat keys.
def pct($x): if $x == null then null else ($x | floor) end;

(.limits // []) as $L
| ([$L[] | select(.kind == "session")]    | first) as $s
| ([$L[] | select(.kind == "weekly_all")] | first) as $w
| ([$L[] | select(.kind == "weekly_scoped")]
   | sort_by(-(.percent // 0)) | first)            as $sc
| {
    session:      (pct($s.percent)  // pct(.five_hour.utilization)  // 0),
    weekly:       (pct($w.percent)  // pct(.seven_day.utilization)  // 0),
    scoped:       (pct($sc.percent) // pct(.seven_day_opus.utilization) // -1),
    scoped_model: (($sc.scope.model.display_name) // "scoped"),
    severity:     ([$s.severity, $w.severity, $sc.severity]
                   | map(select(. != null))
                   | if any(. == "critical") then "critical"
                     elif any(. == "warning") then "warning"
                     else "normal" end),
    session_resets_at: ($s.resets_at // .five_hour.resets_at // ""),
    weekly_resets_at:  ($w.resets_at // .seven_day.resets_at  // ""),
    extra:        (.extra_usage.utilization),
    spend:        (.spend.percent)
  }
