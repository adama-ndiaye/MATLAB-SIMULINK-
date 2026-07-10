%% build_and_run_site_grid_behavior_model.m
% Future City Fellowship GMU
% Professional Site-Level EV Charging Grid Behavior Model
%
% What this does:
% 1. Reads site/year scenarios from site_year_scenarios_from_andy_v2.csv.
% 2. Builds 24-hour base building load and EV charging demand profiles.
% 3. Programmatically creates a Simulink model.
% 4. Compares unmanaged charging vs managed charging.
% 5. Creates professional MATLAB plots.
% 6. Creates an interactive dashboard with a time slider.
% 7. Optionally creates an animated GIF for presentation use.
%
% This is a planning-level site electrical-readiness model.
% It does NOT replace utility interconnection review or detailed feeder study.
%
% Required:
% - MATLAB
% - Simulink

clear; clc; close all;

%% USER SETTINGS

csvFile = "site_year_scenarios_from_andy_v2.csv";

if ~isfile(csvFile)
    altFile = fullfile("data", "site_year_scenarios_from_andy_v2.csv");
    if isfile(altFile)
        csvFile = altFile;
    end
end

selectedSite = "City of Fairfax Regional Library";
selectedYear = "Now";

runAllYearsAfter = true;

outputFolder = fullfile(pwd, "outputs");
saveFigures = true;
createInteractiveDashboard = true;
createAnimatedGIF = true;

if ~exist(outputFolder, "dir")
    mkdir(outputFolder);
end

%% RUN ONE SCENARIO AND BUILD SIMULINK MODEL

scenario = loadScenario(csvFile, selectedSite, selectedYear);
profiles = makeProfiles(scenario);

assignin("base","baseLoad_ts",profiles.baseLoad_ts);
assignin("base","evRequest_ts",profiles.evRequest_ts);
assignin("base","capacity_ts",profiles.capacity_ts);

modelName = "site_grid_behavior_ev_charging";
buildModel(modelName);

open_system(modelName);
fprintf("\nRunning Simulink model for %s - %s...\n", selectedSite, selectedYear);
simOut = sim(modelName);

plotScenario(profiles, scenario, outputFolder, saveFigures);

if createInteractiveDashboard
    try
        createDashboard(profiles, scenario);
    catch ME
        warning("Interactive dashboard could not be created: %s", ME.message);
    end
end

if createAnimatedGIF
    try
        createLoadAnimation(profiles, scenario, outputFolder, saveFigures);
    catch ME
        warning("Animated GIF could not be created: %s", ME.message);
    end
end

printSummary(profiles, scenario);

%% OPTIONAL: COMPARE NOW / 2035 / 2050 FOR ONE SITE

if runAllYearsAfter
    years = ["Now","2035","2050"];
    allProfiles = cell(numel(years),1);
    allScenarios = cell(numel(years),1);

    for i = 1:numel(years)
        allScenarios{i} = loadScenario(csvFile, selectedSite, years(i));
        allProfiles{i} = makeProfiles(allScenarios{i});
    end

    plotYearComparison(allProfiles, allScenarios, outputFolder, saveFigures);
    printYearComparison(allProfiles, allScenarios);
end

%% LOCAL FUNCTIONS

function scenario = loadScenario(csvFile, siteName, yearName)
    if ~isfile(csvFile)
        error("CSV file not found: %s", csvFile);
    end

    opts = detectImportOptions(csvFile);
    opts = setvartype(opts, ["scenario_id","site_name","year"], "string");
    tbl = readtable(csvFile, opts);

    idx = tbl.site_name == siteName & tbl.year == yearName;

    if ~any(idx)
        availableSites = unique(tbl.site_name);
        fprintf("\nAvailable site names in the CSV:\n");
        disp(availableSites);
        error("No matching row found for site '%s' and year '%s'. Check selectedSite and selectedYear.", siteName, yearName);
    end

    row = tbl(find(idx,1),:);

    scenario.scenario_id = string(row.scenario_id);
    scenario.site_name = string(row.site_name);
    scenario.year = string(row.year);
    scenario.ports = double(row.ports);
    scenario.charger_power_kW = double(row.charger_power_kW);
    scenario.spare_capacity_kW = double(row.spare_capacity_kW);
    scenario.base_load_mean_kW = double(row.base_load_mean_kW);
    scenario.base_load_peak_kW = double(row.base_load_peak_kW);
    scenario.arrival_start_hr = double(row.arrival_start_hr);
    scenario.arrival_end_hr = double(row.arrival_end_hr);
    scenario.dwell_hr = double(row.dwell_hr);
end

function profiles = makeProfiles(s)
    dt_min = 5;
    t_hr = (0:dt_min/60:24)';
    t_sec = t_hr * 3600;

    daytimeShape = exp(-0.5*((t_hr - 14)/4.5).^2);
    morningShape = 0.25 * exp(-0.5*((t_hr - 8)/1.7).^2);
    eveningShape = 0.15 * exp(-0.5*((t_hr - 19)/2.0).^2);

    shape = daytimeShape + morningShape + eveningShape;
    shape = shape / max(shape);

    baseLoad_kW = s.base_load_mean_kW + ...
        (s.base_load_peak_kW - s.base_load_mean_kW) * shape;

    fullEV_kW = s.ports * s.charger_power_kW;

    center = (s.arrival_start_hr + s.arrival_end_hr)/2;
    width = max((s.arrival_end_hr - s.arrival_start_hr)/2, 0.5);

    arrivalShape = exp(-0.5*((t_hr - center)/width).^2);
    arrivalShape = arrivalShape / max(arrivalShape);

    evRequest_kW = fullEV_kW * arrivalShape;

    capacity_kW = s.base_load_mean_kW + s.spare_capacity_kW;
    capacity_kW_vec = capacity_kW * ones(size(t_hr));

    availableForEV_kW = max(capacity_kW_vec - baseLoad_kW, 0);
    evManaged_kW = min(evRequest_kW, availableForEV_kW);

    totalUnmanaged_kW = baseLoad_kW + evRequest_kW;
    totalManaged_kW = baseLoad_kW + evManaged_kW;

    overloadUnmanaged_kW = max(totalUnmanaged_kW - capacity_kW_vec, 0);
    overloadManaged_kW = max(totalManaged_kW - capacity_kW_vec, 0);

    energyRequested_kWh = trapz(t_hr, evRequest_kW);
    energyDeliveredManaged_kWh = trapz(t_hr, evManaged_kW);
    curtailedEnergy_kWh = max(energyRequested_kWh - energyDeliveredManaged_kWh, 0);

    profiles.t_hr = t_hr;
    profiles.t_sec = t_sec;
    profiles.baseLoad_kW = baseLoad_kW;
    profiles.evRequest_kW = evRequest_kW;
    profiles.evManaged_kW = evManaged_kW;
    profiles.totalUnmanaged_kW = totalUnmanaged_kW;
    profiles.totalManaged_kW = totalManaged_kW;
    profiles.capacity_kW = capacity_kW_vec;
    profiles.overloadUnmanaged_kW = overloadUnmanaged_kW;
    profiles.overloadManaged_kW = overloadManaged_kW;
    profiles.energyRequested_kWh = energyRequested_kWh;
    profiles.energyDeliveredManaged_kWh = energyDeliveredManaged_kWh;
    profiles.curtailedEnergy_kWh = curtailedEnergy_kWh;

    profiles.baseLoad_ts = timeseries(baseLoad_kW, t_sec);
    profiles.evRequest_ts = timeseries(evRequest_kW, t_sec);
    profiles.capacity_ts = timeseries(capacity_kW_vec, t_sec);
end

function buildModel(modelName)
    if bdIsLoaded(modelName)
        close_system(modelName, 0);
    end

    if isfile(modelName + ".slx")
        delete(modelName + ".slx");
    end

    new_system(modelName);
    open_system(modelName);

    set_param(modelName, "StopTime", "86400");
    set_param(modelName, "Solver", "ode3");
    set_param(modelName, "FixedStep", "300");

    add_block("simulink/Sources/From Workspace", modelName + "/Base Load", ...
        "Position", [40 70 160 100], ...
        "VariableName", "baseLoad_ts");

    add_block("simulink/Sources/From Workspace", modelName + "/EV Request", ...
        "Position", [40 160 160 190], ...
        "VariableName", "evRequest_ts");

    add_block("simulink/Sources/From Workspace", modelName + "/Capacity Limit", ...
        "Position", [40 250 160 280], ...
        "VariableName", "capacity_ts");

    add_block("simulink/Math Operations/Sum", modelName + "/Total Unmanaged", ...
        "Position", [245 115 295 160], ...
        "Inputs", "++");

    add_block("simulink/Signal Routing/Mux", modelName + "/Managed Logic Inputs", ...
        "Position", [240 215 250 295], ...
        "Inputs", "3");

    add_block("simulink/User-Defined Functions/MATLAB Function", modelName + "/Managed EV Power", ...
        "Position", [330 225 490 285]);

    rt = sfroot;
    chart = rt.find("-isa","Stateflow.EMChart","Path", modelName + "/Managed EV Power");

    chart.Script = ['function y = fcn(u)' newline ...
                    '% u(1) = EV request' newline ...
                    '% u(2) = site capacity' newline ...
                    '% u(3) = base building load' newline ...
                    'available = max(u(2) - u(3), 0);' newline ...
                    'y = min(u(1), available);' newline ...
                    'end'];

    add_block("simulink/Math Operations/Sum", modelName + "/Total Managed", ...
        "Position", [570 160 620 205], ...
        "Inputs", "++");

    add_block("simulink/Signal Routing/Mux", modelName + "/Main Scope Signals", ...
        "Position", [715 80 730 260], ...
        "Inputs", "4");

    add_block("simulink/Sinks/Scope", modelName + "/Live Scope: Load Behavior", ...
        "Position", [810 115 970 220]);

    add_block("simulink/Sinks/To Workspace", modelName + "/toWorkspace_unmanaged", ...
        "Position", [715 310 875 340], ...
        "VariableName", "sim_total_unmanaged", ...
        "SaveFormat", "Structure With Time");

    add_block("simulink/Sinks/To Workspace", modelName + "/toWorkspace_managed", ...
        "Position", [715 360 875 390], ...
        "VariableName", "sim_total_managed", ...
        "SaveFormat", "Structure With Time");

    add_line(modelName, "Base Load/1", "Total Unmanaged/1");
    add_line(modelName, "EV Request/1", "Total Unmanaged/2");

    add_line(modelName, "EV Request/1", "Managed Logic Inputs/1");
    add_line(modelName, "Capacity Limit/1", "Managed Logic Inputs/2");
    add_line(modelName, "Base Load/1", "Managed Logic Inputs/3");
    add_line(modelName, "Managed Logic Inputs/1", "Managed EV Power/1");

    add_line(modelName, "Base Load/1", "Total Managed/1");
    add_line(modelName, "Managed EV Power/1", "Total Managed/2");

    add_line(modelName, "Base Load/1", "Main Scope Signals/1");
    add_line(modelName, "Total Unmanaged/1", "Main Scope Signals/2");
    add_line(modelName, "Total Managed/1", "Main Scope Signals/3");
    add_line(modelName, "Capacity Limit/1", "Main Scope Signals/4");
    add_line(modelName, "Main Scope Signals/1", "Live Scope: Load Behavior/1");

    add_line(modelName, "Total Unmanaged/1", "toWorkspace_unmanaged/1");
    add_line(modelName, "Total Managed/1", "toWorkspace_managed/1");

    try
        Simulink.BlockDiagram.arrangeSystem(modelName);
    catch
    end

    save_system(modelName);
end

function plotScenario(p, s, outputFolder, saveFigures)
    siteLabel = strrep(string(s.site_name), "_", " ");
    scenarioLabel = string(s.year);

    cBase = [0.12 0.32 0.65];
    cUnmanaged = [0.82 0.20 0.16];
    cManaged = [0.13 0.55 0.36];
    cCapacity = [0.32 0.22 0.55];
    cEV = [0.95 0.58 0.16];
    cGray = [0.35 0.35 0.35];

    fig = figure("Name", "Professional Site-Level EV Charging Analysis", ...
                 "Color", "w", ...
                 "Units", "pixels", ...
                 "Position", [80 60 1450 820]);

    t = tiledlayout(fig, 2, 2, ...
        "TileSpacing", "compact", ...
        "Padding", "compact");

    title(t, "EV Charging Site-Load Behavior", ...
        "FontWeight", "bold", ...
        "FontSize", 20);

    subtitle(t, siteLabel + " | Scenario: " + scenarioLabel + ...
        " | Recommended ports: " + string(s.ports) + ...
        " | Charger power: " + string(s.charger_power_kW) + " kW/port");

    ax1 = nexttile(t, [1 2]);
    hold(ax1, "on"); grid(ax1, "on"); box(ax1, "on");

    overloadIdx = p.totalUnmanaged_kW > p.capacity_kW;

    if any(overloadIdx)
        xFill = [p.t_hr(overloadIdx); flipud(p.t_hr(overloadIdx))];
        yFill = [p.capacity_kW(overloadIdx); flipud(p.totalUnmanaged_kW(overloadIdx))];

        fill(ax1, xFill, yFill, cUnmanaged, ...
            "FaceAlpha", 0.15, ...
            "EdgeColor", "none", ...
            "DisplayName", "Unmanaged overload area");
    end

    plot(ax1, p.t_hr, p.baseLoad_kW, ...
        "Color", cBase, ...
        "LineWidth", 2.5, ...
        "DisplayName", "Base building load");

    plot(ax1, p.t_hr, p.totalUnmanaged_kW, ...
        "Color", cUnmanaged, ...
        "LineWidth", 3.0, ...
        "DisplayName", "Total load without managed charging");

    plot(ax1, p.t_hr, p.totalManaged_kW, ...
        "Color", cManaged, ...
        "LineWidth", 3.0, ...
        "DisplayName", "Total load with managed charging");

    plot(ax1, p.t_hr, p.capacity_kW, ...
        "--", ...
        "Color", cCapacity, ...
        "LineWidth", 3.0, ...
        "DisplayName", "Site capacity limit");

    xlabel(ax1, "Hour of day", "FontWeight", "bold");
    ylabel(ax1, "Power demand (kW)", "FontWeight", "bold");
    title(ax1, "24-Hour Site Load Profile", "FontWeight", "bold");

    xlim(ax1, [0 24]);
    xticks(ax1, 0:2:24);

    yMax = max([p.totalUnmanaged_kW; p.totalManaged_kW; p.capacity_kW]) * 1.15;
    ylim(ax1, [0 yMax]);

    legend(ax1, "Location", "northoutside", ...
        "Orientation", "horizontal", ...
        "NumColumns", 2);

    formatAxes(ax1);

    ax2 = nexttile(t);
    hold(ax2, "on"); grid(ax2, "on"); box(ax2, "on");

    curtailIdx = p.evRequest_kW > p.evManaged_kW;

    if any(curtailIdx)
        xFill = [p.t_hr(curtailIdx); flipud(p.t_hr(curtailIdx))];
        yFill = [p.evManaged_kW(curtailIdx); flipud(p.evRequest_kW(curtailIdx))];

        fill(ax2, xFill, yFill, cUnmanaged, ...
            "FaceAlpha", 0.13, ...
            "EdgeColor", "none", ...
            "DisplayName", "Curtailed/delayed power");
    end

    plot(ax2, p.t_hr, p.evRequest_kW, ...
        "Color", cEV, ...
        "LineWidth", 3.0, ...
        "DisplayName", "EV charging request");

    plot(ax2, p.t_hr, p.evManaged_kW, ...
        "Color", cManaged, ...
        "LineWidth", 3.0, ...
        "DisplayName", "Managed EV charging output");

    xlabel(ax2, "Hour of day", "FontWeight", "bold");
    ylabel(ax2, "EV charging power (kW)", "FontWeight", "bold");
    title(ax2, "EV Charging Request vs Managed Output", "FontWeight", "bold");

    xlim(ax2, [0 24]);
    xticks(ax2, 0:4:24);

    yMax2 = max([p.evRequest_kW; p.evManaged_kW]) * 1.25;

    if yMax2 <= 0
        yMax2 = 10;
    end

    ylim(ax2, [0 yMax2]);

    legend(ax2, "Location", "northoutside", "Orientation", "horizontal");
    formatAxes(ax2);

    ax3 = nexttile(t);
    hold(ax3, "on"); grid(ax3, "on"); box(ax3, "on");

    metrics = categorical(["Peak unmanaged", "Peak managed", "Max overload", "Curtailed energy"]);
    metrics = reordercats(metrics, ["Peak unmanaged", "Peak managed", "Max overload", "Curtailed energy"]);

    values = [
        max(p.totalUnmanaged_kW), ...
        max(p.totalManaged_kW), ...
        max(p.overloadUnmanaged_kW), ...
        p.curtailedEnergy_kWh
    ];

    b = bar(ax3, metrics, values);
    b.FaceColor = "flat";
    b.CData(1,:) = cUnmanaged;
    b.CData(2,:) = cManaged;
    b.CData(3,:) = cCapacity;
    b.CData(4,:) = cGray;

    ylabel(ax3, "Value", "FontWeight", "bold");
    title(ax3, "Scenario Summary Metrics", "FontWeight", "bold");
    xtickangle(ax3, 20);

    for i = 1:numel(values)
        text(ax3, i, values(i) + max(values)*0.035 + 0.01, ...
            string(round(values(i),1)), ...
            "HorizontalAlignment", "center", ...
            "FontWeight", "bold", ...
            "FontSize", 10);
    end

    ylim(ax3, [0 max(values)*1.25 + 1]);
    formatAxes(ax3);

    maxUnmanagedOverload = max(p.overloadUnmanaged_kW);
    maxManagedOverload = max(p.overloadManaged_kW);

    if maxUnmanagedOverload > 0 && maxManagedOverload == 0
        resultText = "Result: unmanaged charging exceeds site capacity, while managed charging keeps total load within the modeled limit.";
        noteColor = [1.00 0.93 0.89];
    elseif maxUnmanagedOverload > 0 && maxManagedOverload > 0
        resultText = "Result: both unmanaged and managed charging show overload risk; site may need capacity upgrades or fewer ports.";
        noteColor = [1.00 0.88 0.88];
    else
        resultText = "Result: this scenario stays within modeled site capacity. No overload is observed under current assumptions.";
        noteColor = [0.90 0.97 0.92];
    end

    annotation(fig, "textbox", [0.13 0.01 0.74 0.045], ...
        "String", resultText, ...
        "FitBoxToText", "off", ...
        "BackgroundColor", noteColor, ...
        "EdgeColor", [0.70 0.70 0.70], ...
        "FontSize", 11, ...
        "FontWeight", "bold", ...
        "HorizontalAlignment", "center");

    if saveFigures
        outFile = fullfile(outputFolder, ...
            "professional_site_load_" + safeName(s.site_name) + "_" + safeName(s.year) + ".png");

        saveFigure(fig, outFile);
        fprintf("Saved professional figure: %s\n", outFile);
    end
end

function plotYearComparison(allProfiles, allScenarios, outputFolder, saveFigures)
    siteLabel = strrep(string(allScenarios{1}.site_name), "_", " ");

    cNow = [0.12 0.32 0.65];
    c2035 = [0.90 0.43 0.14];
    c2050 = [0.13 0.55 0.36];
    cCapacity = [0.32 0.22 0.55];
    cUnmanaged = [0.82 0.20 0.16];
    cManaged = [0.13 0.55 0.36];

    fig = figure("Name", "Professional Year Comparison", ...
                 "Color", "w", ...
                 "Units", "pixels", ...
                 "Position", [100 70 1450 820]);

    t = tiledlayout(fig, 2, 2, ...
        "TileSpacing", "compact", ...
        "Padding", "compact");

    title(t, "Planning-Year Comparison: Managed EV Charging Load", ...
        "FontWeight", "bold", ...
        "FontSize", 20);

    subtitle(t, siteLabel + " | Now / 2035 / 2050 scenarios");

    ax1 = nexttile(t, [1 2]);
    hold(ax1, "on"); grid(ax1, "on"); box(ax1, "on");

    colors = {cNow, c2035, c2050};

    for i = 1:numel(allProfiles)
        p = allProfiles{i};
        s = allScenarios{i};

        plot(ax1, p.t_hr, p.totalManaged_kW, ...
            "LineWidth", 3.0, ...
            "Color", colors{i}, ...
            "DisplayName", string(s.year) + " managed total (" + string(s.ports) + " ports)");
    end

    plot(ax1, allProfiles{1}.t_hr, allProfiles{1}.capacity_kW, ...
        "--", ...
        "LineWidth", 3.0, ...
        "Color", cCapacity, ...
        "DisplayName", "Site capacity limit");

    xlabel(ax1, "Hour of day", "FontWeight", "bold");
    ylabel(ax1, "Power demand (kW)", "FontWeight", "bold");
    title(ax1, "Managed Charging Load Across Planning Years", "FontWeight", "bold");

    xlim(ax1, [0 24]);
    xticks(ax1, 0:2:24);

    allY = [];

    for i = 1:numel(allProfiles)
        allY = [allY; allProfiles{i}.totalManaged_kW; allProfiles{i}.capacity_kW];
    end

    ylim(ax1, [0 max(allY)*1.15]);

    legend(ax1, "Location", "northoutside", ...
        "Orientation", "horizontal", ...
        "NumColumns", 2);

    formatAxes(ax1);

    ax2 = nexttile(t);
    hold(ax2, "on"); grid(ax2, "on"); box(ax2, "on");

    years = strings(numel(allProfiles),1);
    ports = zeros(numel(allProfiles),1);
    peakManaged = zeros(numel(allProfiles),1);
    peakUnmanaged = zeros(numel(allProfiles),1);
    maxOverload = zeros(numel(allProfiles),1);

    for i = 1:numel(allProfiles)
        years(i) = string(allScenarios{i}.year);
        ports(i) = allScenarios{i}.ports;
        peakManaged(i) = max(allProfiles{i}.totalManaged_kW);
        peakUnmanaged(i) = max(allProfiles{i}.totalUnmanaged_kW);
        maxOverload(i) = max(allProfiles{i}.overloadUnmanaged_kW);
    end

    x = categorical(years);
    x = reordercats(x, cellstr(years));

    bPorts = bar(ax2, x, ports);
    bPorts.FaceColor = cNow;

    ylabel(ax2, "Recommended ports", "FontWeight", "bold");
    title(ax2, "Recommended Port Count", "FontWeight", "bold");

    for i = 1:numel(ports)
        text(ax2, i, ports(i) + 0.15, string(ports(i)), ...
            "HorizontalAlignment", "center", ...
            "FontWeight", "bold");
    end

    ylim(ax2, [0 max(ports)*1.35 + 1]);
    formatAxes(ax2);

    ax3 = nexttile(t);
    hold(ax3, "on"); grid(ax3, "on"); box(ax3, "on");

    b = bar(ax3, x, [peakUnmanaged peakManaged], "grouped");
    b(1).FaceColor = cUnmanaged;
    b(2).FaceColor = cManaged;

    plot(ax3, x, maxOverload, "-o", ...
        "Color", cCapacity, ...
        "LineWidth", 2.8, ...
        "MarkerSize", 7, ...
        "DisplayName", "Max unmanaged overload");

    ylabel(ax3, "Power (kW)", "FontWeight", "bold");
    title(ax3, "Peak Load and Overload Risk", "FontWeight", "bold");

    legend(ax3, ["Peak unmanaged", "Peak managed", "Max overload"], ...
        "Location", "northoutside", ...
        "Orientation", "horizontal");

    yMax = max([peakUnmanaged; peakManaged; maxOverload]) * 1.25;

    if yMax <= 0
        yMax = 10;
    end

    ylim(ax3, [0 yMax]);
    formatAxes(ax3);

    if saveFigures
        outFile = fullfile(outputFolder, ...
            "professional_year_comparison_" + safeName(allScenarios{1}.site_name) + ".png");

        saveFigure(fig, outFile);
        fprintf("Saved professional year comparison figure: %s\n", outFile);
    end
end

function createDashboard(p, s)
    siteLabel = strrep(string(s.site_name), "_", " ");

    cBase = [0.12 0.32 0.65];
    cUnmanaged = [0.82 0.20 0.16];
    cManaged = [0.13 0.55 0.36];
    cCapacity = [0.32 0.22 0.55];
    cEV = [0.95 0.58 0.16];

    fig = uifigure("Name", "Interactive EV Charging Load Dashboard", ...
                   "Position", [100 100 1250 760]);

    uilabel(fig, ...
        "Text", "Interactive EV Charging Load Dashboard", ...
        "Position", [40 715 1000 30], ...
        "FontSize", 20, ...
        "FontWeight", "bold");

    uilabel(fig, ...
        "Text", siteLabel + " | Scenario: " + string(s.year) + ...
        " | Ports: " + string(s.ports) + ...
        " | Charger: " + string(s.charger_power_kW) + " kW/port", ...
        "Position", [40 690 1100 25], ...
        "FontSize", 13);

    mainAx = uiaxes(fig, "Position", [55 255 760 410]);
    evAx = uiaxes(fig, "Position", [855 255 330 410]);

    timeSlider = uislider(fig, ...
        "Position", [90 170 900 3], ...
        "Limits", [0 24], ...
        "Value", 12);

    timeSlider.MajorTicks = 0:4:24;
    timeSlider.MinorTicks = 0:1:24;

    currentLabel = uilabel(fig, ...
        "Text", "Hour: 12.0", ...
        "Position", [90 190 250 25], ...
        "FontSize", 13, ...
        "FontWeight", "bold");

    loadLabel = uilabel(fig, ...
        "Text", "", ...
        "Position", [360 190 820 25], ...
        "FontSize", 13);

    uibutton(fig, "push", ...
        "Text", "Play 24-hour animation", ...
        "Position", [90 95 200 38], ...
        "FontSize", 13, ...
        "ButtonPushedFcn", @(src,event) playDashboard());

    uilabel(fig, ...
        "Text", "Move the slider to inspect site load, EV charging demand, and managed charging behavior at any hour.", ...
        "Position", [320 98 850 30], ...
        "FontSize", 12);

    updateDashboard(12);

    timeSlider.ValueChangingFcn = @(src,event) updateDashboard(event.Value);
    timeSlider.ValueChangedFcn = @(src,event) updateDashboard(src.Value);

    function updateDashboard(currentHour)
        [~, idx] = min(abs(p.t_hr - currentHour));

        cla(mainAx);
        hold(mainAx, "on"); grid(mainAx, "on"); box(mainAx, "on");

        plot(mainAx, p.t_hr, p.baseLoad_kW, ...
            "Color", cBase, ...
            "LineWidth", 2.2, ...
            "DisplayName", "Base load");

        plot(mainAx, p.t_hr, p.totalUnmanaged_kW, ...
            "Color", cUnmanaged, ...
            "LineWidth", 2.6, ...
            "DisplayName", "Unmanaged total");

        plot(mainAx, p.t_hr, p.totalManaged_kW, ...
            "Color", cManaged, ...
            "LineWidth", 2.6, ...
            "DisplayName", "Managed total");

        plot(mainAx, p.t_hr, p.capacity_kW, ...
            "--", ...
            "Color", cCapacity, ...
            "LineWidth", 2.5, ...
            "DisplayName", "Capacity limit");

        xline(mainAx, p.t_hr(idx), "k:", "LineWidth", 1.8);

        scatter(mainAx, p.t_hr(idx), p.totalUnmanaged_kW(idx), ...
            70, cUnmanaged, "filled");

        scatter(mainAx, p.t_hr(idx), p.totalManaged_kW(idx), ...
            70, cManaged, "filled");

        xlabel(mainAx, "Hour of day");
        ylabel(mainAx, "Power demand (kW)");
        title(mainAx, "24-Hour Site Load Behavior");

        xlim(mainAx, [0 24]);
        xticks(mainAx, 0:2:24);

        yMax = max([p.totalUnmanaged_kW; p.totalManaged_kW; p.capacity_kW]) * 1.15;
        ylim(mainAx, [0 yMax]);

        legend(mainAx, "Location", "northoutside", ...
            "Orientation", "horizontal", ...
            "NumColumns", 2);

        formatAxes(mainAx);

        cla(evAx);
        hold(evAx, "on"); grid(evAx, "on"); box(evAx, "on");

        cats = categorical(["Request", "Allowed"]);
        cats = reordercats(cats, ["Request", "Allowed"]);

        b = bar(evAx, cats, [p.evRequest_kW(idx), p.evManaged_kW(idx)]);
        b.FaceColor = "flat";
        b.CData(1,:) = cEV;
        b.CData(2,:) = cManaged;

        ylabel(evAx, "EV power (kW)");
        title(evAx, "EV Charging at Selected Hour");

        yMaxEV = max([p.evRequest_kW; p.evManaged_kW]) * 1.25;

        if yMaxEV <= 0
            yMaxEV = 10;
        end

        ylim(evAx, [0 yMaxEV]);
        formatAxes(evAx);

        currentLabel.Text = "Hour: " + string(round(p.t_hr(idx),2));

        overloadNow = max(p.totalUnmanaged_kW(idx) - p.capacity_kW(idx), 0);

        loadLabel.Text = "Base load: " + string(round(p.baseLoad_kW(idx),1)) + " kW   |   " + ...
                         "EV request: " + string(round(p.evRequest_kW(idx),1)) + " kW   |   " + ...
                         "Managed EV: " + string(round(p.evManaged_kW(idx),1)) + " kW   |   " + ...
                         "Unmanaged overload: " + string(round(overloadNow,1)) + " kW";
    end

    function playDashboard()
        for val = linspace(0, 24, 120)
            if ~isvalid(fig)
                return;
            end

            timeSlider.Value = val;
            updateDashboard(val);
            drawnow limitrate;
            pause(0.03);
        end
    end
end

function createLoadAnimation(p, s, outputFolder, saveFigures)
    if ~saveFigures
        return;
    end

    if ~exist(outputFolder, "dir")
        mkdir(outputFolder);
    end

    siteLabel = strrep(string(s.site_name), "_", " ");

    cBase = [0.12 0.32 0.65];
    cUnmanaged = [0.82 0.20 0.16];
    cManaged = [0.13 0.55 0.36];
    cCapacity = [0.32 0.22 0.55];

    fig = figure("Name", "Animated Site Load Behavior", ...
                 "Color", "w", ...
                 "Units", "pixels", ...
                 "Position", [100 100 1200 700]);

    ax = axes(fig);
    hold(ax, "on"); grid(ax, "on"); box(ax, "on");

    plot(ax, p.t_hr, p.baseLoad_kW, ...
        "Color", cBase, ...
        "LineWidth", 2.4, ...
        "DisplayName", "Base building load");

    plot(ax, p.t_hr, p.totalUnmanaged_kW, ...
        "Color", cUnmanaged, ...
        "LineWidth", 2.8, ...
        "DisplayName", "Total load without managed charging");

    plot(ax, p.t_hr, p.totalManaged_kW, ...
        "Color", cManaged, ...
        "LineWidth", 2.8, ...
        "DisplayName", "Total load with managed charging");

    plot(ax, p.t_hr, p.capacity_kW, ...
        "--", ...
        "Color", cCapacity, ...
        "LineWidth", 2.8, ...
        "DisplayName", "Site capacity limit");

    yMax = max([p.totalUnmanaged_kW; p.totalManaged_kW; p.capacity_kW]) * 1.15;

    timeLine = line(ax, [0 0], [0 yMax], ...
        "Color", [0 0 0], ...
        "LineStyle", ":", ...
        "LineWidth", 2.0);

    unmanagedPoint = scatter(ax, 0, p.totalUnmanaged_kW(1), ...
        90, cUnmanaged, "filled");

    managedPoint = scatter(ax, 0, p.totalManaged_kW(1), ...
        90, cManaged, "filled");

    timeText = text(ax, 0.6, yMax*0.92, "Hour: 0.0", ...
        "FontSize", 13, ...
        "FontWeight", "bold", ...
        "BackgroundColor", "w", ...
        "EdgeColor", [0.75 0.75 0.75]);

    xlabel(ax, "Hour of day", "FontWeight", "bold");
    ylabel(ax, "Power demand (kW)", "FontWeight", "bold");

    title(ax, ["Animated Site Load Behavior", ...
               siteLabel + " | Scenario: " + string(s.year)], ...
        "FontWeight", "bold");

    xlim(ax, [0 24]);
    ylim(ax, [0 yMax]);
    xticks(ax, 0:2:24);

    legend(ax, "Location", "northoutside", ...
        "Orientation", "horizontal", ...
        "NumColumns", 2);

    formatAxes(ax);

    gifFile = fullfile(outputFolder, ...
        "animated_site_load_" + safeName(s.site_name) + "_" + safeName(s.year) + ".gif");

    frameStep = 3;
    frameIndices = 1:frameStep:numel(p.t_hr);

    for frameNum = 1:numel(frameIndices)
        k = frameIndices(frameNum);
        currentHour = p.t_hr(k);

        timeLine.XData = [currentHour currentHour];

        unmanagedPoint.XData = currentHour;
        unmanagedPoint.YData = p.totalUnmanaged_kW(k);

        managedPoint.XData = currentHour;
        managedPoint.YData = p.totalManaged_kW(k);

        timeText.String = "Hour: " + string(round(currentHour,2));
        timeText.Position = [min(currentHour + 0.4, 20.5), yMax*0.92, 0];

        drawnow;

        frame = getframe(fig);
        im = frame2im(frame);
        [A,map] = rgb2ind(im,256);

        if frameNum == 1
            imwrite(A,map,gifFile,"gif", ...
                "LoopCount",Inf, ...
                "DelayTime",0.06);
        else
            imwrite(A,map,gifFile,"gif", ...
                "WriteMode","append", ...
                "DelayTime",0.06);
        end
    end

    fprintf("Saved animated GIF: %s\n", gifFile);
end

function printSummary(p, s)
    fprintf("\nSITE-LEVEL GRID BEHAVIOR SUMMARY\n");
    fprintf("--------------------------------\n");
    fprintf("Site: %s\n", s.site_name);
    fprintf("Year/scenario: %s\n", s.year);
    fprintf("Ports from right-sizing model: %.0f\n", s.ports);
    fprintf("Charger power per port: %.1f kW\n", s.charger_power_kW);
    fprintf("Maximum EV request: %.1f kW\n", max(p.evRequest_kW));
    fprintf("Spare capacity input: %.1f kW\n", s.spare_capacity_kW);
    fprintf("Site capacity limit used in simulation: %.1f kW\n", p.capacity_kW(1));
    fprintf("Peak base load: %.1f kW\n", max(p.baseLoad_kW));
    fprintf("Peak unmanaged total load: %.1f kW\n", max(p.totalUnmanaged_kW));
    fprintf("Peak managed total load: %.1f kW\n", max(p.totalManaged_kW));
    fprintf("Max unmanaged overload: %.1f kW\n", max(p.overloadUnmanaged_kW));
    fprintf("Max managed overload: %.1f kW\n", max(p.overloadManaged_kW));
    fprintf("Requested EV energy: %.1f kWh/day\n", p.energyRequested_kWh);
    fprintf("Managed delivered EV energy: %.1f kWh/day\n", p.energyDeliveredManaged_kWh);
    fprintf("Curtailed/delayed EV energy: %.1f kWh/day\n\n", p.curtailedEnergy_kWh);
end

function printYearComparison(allProfiles, allScenarios)
    fprintf("\nNOW / 2035 / 2050 COMPARISON\n");
    fprintf("----------------------------\n");
    fprintf("%-8s %-7s %-15s %-16s %-16s %-16s\n", ...
        "Year", "Ports", "Peak unmanaged", "Peak managed", "Max overload", "Curtailed kWh");

    for i = 1:numel(allProfiles)
        p = allProfiles{i};
        s = allScenarios{i};

        fprintf("%-8s %-7.0f %-15.1f %-16.1f %-16.1f %-16.1f\n", ...
            s.year, ...
            s.ports, ...
            max(p.totalUnmanaged_kW), ...
            max(p.totalManaged_kW), ...
            max(p.overloadUnmanaged_kW), ...
            p.curtailedEnergy_kWh);
    end

    fprintf("\n");
end

function formatAxes(ax)
    ax.FontSize = 11;
    ax.LineWidth = 1.1;
    ax.GridAlpha = 0.20;

    try
        ax.MinorGridAlpha = 0.10;
    catch
    end
end

function saveFigure(fig, outFile)
    outFile = char(outFile);
    outDir = fileparts(outFile);

    if ~isempty(outDir) && ~exist(outDir, "dir")
        mkdir(outDir);
    end

    try
        exportgraphics(fig, outFile, "Resolution", 300);
    catch
        try
            saveas(fig, outFile);
        catch ME
            warning("Figure could not be saved to %s. Error: %s", outFile, ME.message);
        end
    end
end

function nameOut = safeName(nameIn)
    nameOut = regexprep(char(string(nameIn)), '[^a-zA-Z0-9]+', '_');
    nameOut = string(nameOut);
end