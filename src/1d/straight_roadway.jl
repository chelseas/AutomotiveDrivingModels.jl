type StraightRoadway
    length::Float64
end

function mod_position_to_roadway(s::Float64, roadway::StraightRoadway)
    while s > roadway.length
        s -= roadway.length
    end
    while s < 0
        s += roadway.length
    end
    return s
end
