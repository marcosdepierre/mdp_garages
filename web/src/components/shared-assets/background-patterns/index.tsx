// mdp patch (QC N3): only the 'circle' pattern is bundled.
import type { SVGProps } from "react";
import { cx } from "@/utils/cx";
import { Circle } from "./circle";

const patterns = {
    circle: Circle,
};

export interface BackgroundPatternProps extends Omit<SVGProps<SVGSVGElement>, "size"> {
    size?: "sm" | "md" | "lg";
    pattern: keyof typeof patterns;
}

export const BackgroundPattern = (props: BackgroundPatternProps) => {
    const { pattern } = props;
    const Pattern = patterns[pattern];

    return <Pattern {...props} size={props.size as "sm" | "md"} className={cx("pointer-events-none", props.className)} />;
};
