# Vega Chart

- **Widget ID:** `f1.widget.web.vegachart.VegaChart`
- **Type:** PLUGGABLEWIDGET
- **Version:** 1.0.0

## MDL Example

```sql
PLUGGABLEWIDGET 'f1.widget.web.vegachart.VegaChart' widget1
```

## Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `spec` | string | Yes |  | Vega-Lite or Vega JSON. Which language is used is decided by the spec's own $... |
| `chartData` | attribute |  |  | A JSON array of row objects, bound to the spec's named dataset (or to its top... |
| `datasetName` | string |  | table | The name the spec uses to refer to the data (Vega-Lite: {"data": {"name": "ta... |
| `selection` | attribute |  |  | Written with the clicked mark's datum as JSON. Only the datum's own scalar fi... |
| `onClick` | action |  |  | Runs after the selection attribute is written. Leave empty to make the chart ... |
| `chartHeight` | integer | Yes | 360 | Height of the chart container. Zero lets the container take the height the ch... |
| `renderer` | enumeration | Yes | svg | SVG keeps marks selectable and styleable by CSS; canvas is faster for very de... |
| `showActions` | boolean | Yes | false | Vega's own export / view-source menu. Off by default so the chart carries no ... |

