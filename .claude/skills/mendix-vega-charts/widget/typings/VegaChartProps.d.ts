/**
 * This file was generated from VegaChart.xml
 * WARNING: All changes made to this file will be overwritten
 * @author Mendix Widgets Framework Team
 */
import { ActionValue, EditableValue } from "mendix";
import { CSSProperties } from "react";

export type RendererEnum = "svg" | "canvas";

export interface VegaChartContainerProps {
    name: string;
    class: string;
    style?: CSSProperties;
    tabIndex?: number;
    spec: string;
    chartData?: EditableValue<string>;
    datasetName: string;
    selection?: EditableValue<string>;
    onClick?: ActionValue;
    chartHeight: number;
    renderer: RendererEnum;
    showActions: boolean;
}

export interface VegaChartPreviewProps {
    /**
     * @deprecated Deprecated since version 9.18.0. Please use class property instead.
     */
    className: string;
    class: string;
    style: string;
    styleObject?: CSSProperties;
    readOnly: boolean;
    renderMode: "design" | "xray" | "structure";
    translate: (text: string) => string;
    spec: string;
    chartData: string;
    datasetName: string;
    selection: string;
    onClick: {} | null;
    chartHeight: number | null;
    renderer: RendererEnum;
    showActions: boolean;
}
