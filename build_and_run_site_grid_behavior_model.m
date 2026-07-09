%% build_and_run_site_grid_behavior_model.m
% Future City Fellowship GMU
% Site-Level EV Charging Grid Behavior Simulink Starter
%
% What this does:
% 1. Reads site/year scenarios from site_year_scenarios.csv.
% 2. Builds 24-hour base building load and EV charging demand profiles.
% 3. Programmatically creates a simple Simulink model.
% 4. Compares unmanaged charging vs managed charging.
% 5. Shows live Simulink Scope visuals and MATLAB summary plots.
%
% This is a site-level electrical-readiness model.
% It does NOT replace utility interconnection review or a detailed feeder study.
%
% Required:
% - MATLAB
% - Simulink
%
% Optional later:
% - Simscape Electrical, if you want to connect this planning layer to a
%   detailed charger/power-electronics model.

clear; clc; close all;

%% USER SETTINGS
csvFile = "site_year_scenarios_from_andy_v2.csv";

% Choose one site name from the CSV.
selectedSite = "City of Fairfax Regional Library";

% Choose which year scenario to run first: "Now", "2035", or "2050".
selectedYear = "Now";

% Set to true if you want the script to loop through Now, 2035, and 2050
% for the selected site after the single Simulink run.
runAllYearsAfter = true;

%% RUN ONE SCENARIO AND BUILD SIMULINK MODEL
scenario = loadScenario(csvFile, selectedSite, selectedYear);
profiles = makeProfiles(scenario);

% Put time series into base workspace for Simulink From Workspace blocks.
assignin("base","baseLoad_ts",profiles.baseLoad_ts);
assignin("base","evRequest_ts",profiles.evRequest_ts);
assignin("base","capacity_ts",profiles.capacity_ts);

% Build or rebuild Simulink model.
modelName = "site_grid_behavior_ev_charging";
buildModel(modelName);

% Open model and run.
open_system(modelName);
fprintf("\nRunning Simulink model for %s - %s...\n", selectedSite, selectedYear);
simOut = sim(modelName);

% MATLAB summary plot for the one scenario.
plotScenario(profiles, scenario);

% Print summary.
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

    plotYearComparison(allProfiles, allScenarios);
    printYearComparison(allProfiles, allScenarios);
end

%% LOCAL FUNCTIONS
function scenario = loadScenario(csvFile, siteName, yearName)
    opts = detectImportOptions(csvFile);
    opts = setvartype(opts, ["scenario_id","site_name","year"], "string");
    tbl = readtable(csvFile, opts);

    idx = tbl.site_name == siteName & tbl.year == yearName;

    if ~any(idx)
        error("No matching row found for site '%s' and year '%s'. Check the CSV.", siteName, yearName);
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
    % Time axis: one full day, 5-minute steps.
    dt_min = 5;
    t_hr = (0:dt_min/60:24)';
    t_sec = t_hr * 3600;

    % Base building load:
    % A smooth daytime curve plus a small morning/evening variation.
    daytimeShape = exp(-0.5*((t_hr - 14)/4.5).^2);
    morningShape = 0.25 * exp(-0.5*((t_hr - 8)/1.7).^2);
    eveningShape = 0.15 * exp(-0.5*((t_hr - 19)/2.0).^2);
    shape = daytimeShape + morningShape + eveningShape;
    shape = shape / max(shape);

    baseLoad_kW = s.base_load_mean_kW + (s.base_load_peak_kW - s.base_load_mean_kW) * shape;

    % EV request profile:
    % This represents when many vehicles are plugged in.
    % It is not total energy demand from the Python model yet; it is a simple
    % first-pass time shape using the recommended number of ports.
    fullEV_kW = s.ports * s.charger_power_kW;

    center = (s.arrival_start_hr + s.arrival_end_hr)/2;
    width = max((s.arrival_end_hr - s.arrival_start_hr)/2, 0.5);

    arrivalShape = exp(-0.5*((t_hr - center)/width).^2);
    arrivalShape = arrivalShape / max(arrivalShape);

    % For a simple first pass, scale EV demand so it peaks at all recommended
    % ports charging together.
    evRequest_kW = fullEV_kW * arrivalShape;

    % Site capacity limit.
    % Here "capacity" means base load plus available spare capacity.
    capacity_kW = s.base_load_mean_kW + s.spare_capacity_kW;
    capacity_kW_vec = capacity_kW * ones(size(t_hr));

    % Managed charging rule:
    % EV allowed power is the lower value between requested EV power and
    % remaining site capacity after base load is served.
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

    % Timeseries for Simulink.
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

    % Blocks
    add_block("simulink/Sources/From Workspace", modelName + "/Base Load", ...
        "Position", [40 70 160 100], "VariableName", "baseLoad_ts");
    add_block("simulink/Sources/From Workspace", modelName + "/EV Request", ...
        "Position", [40 160 160 190], "VariableName", "evRequest_ts");
    add_block("simulink/Sources/From Workspace", modelName + "/Capacity Limit", ...
        "Position", [40 250 160 280], "VariableName", "capacity_ts");

    add_block("simulink/Math Operations/Sum", modelName + "/Total Unmanaged", ...
        "Position", [240 115 285 160], "Inputs", "++");

    add_block("simulink/Signal Routing/Mux", modelName + "/Managed Logic Inputs", ...
        "Position", [240 215 250 295], "Inputs", "3");

    add_block("simulink/User-Defined Functions/MATLAB Function", modelName + "/Managed EV Power", ...
        "Position", [320 230 455 280]);

    rt = sfroot;
    chart = rt.find("-isa","Stateflow.EMChart","Path", modelName + "/Managed EV Power");
    chart.Script = ['function y = fcn(u)' newline ...
                    'available = max(u(2) - u(3), 0);' newline ...
                    'y = min(u(1), available);' newline ...
                    'end'];

    add_block("simulink/Math Operations/Sum", modelName + "/Total Managed", ...
        "Position", [530 160 575 205], "Inputs", "++");

    add_block("simulink/Signal Routing/Mux", modelName + "/Main Scope Signals", ...
        "Position", [665 85 675 250], "Inputs", "4");

    add_block("simulink/Sinks/Scope", modelName + "/Live Scope: Load Behavior", ...
        "Position", [760 115 900 210]);

    add_block("simulink/Sinks/To Workspace", modelName + "/toWorkspace_unmanaged", ...
        "Position", [665 300 815 330], "VariableName", "sim_total_unmanaged", "SaveFormat", "Structure With Time");
    add_block("simulink/Sinks/To Workspace", modelName + "/toWorkspace_managed", ...
        "Position", [665 350 815 380], "VariableName", "sim_total_managed", "SaveFormat", "Structure With Time");

    % Connections
    add_line(modelName, "Base Load/1", "Total Unmanaged/1");
    add_line(modelName, "EV Request/1", "Total Unmanaged/2");

    % Mux order for managed logic:
    % u(1) = EV request, u(2) = capacity, u(3) = base load
    add_line(modelName, "EV Request/1", "Managed Logic Inputs/1");
    add_line(modelName, "Capacity Limit/1", "Managed Logic Inputs/2");
    add_line(modelName, "Base Load/1", "Managed Logic Inputs/3");
    add_line(modelName, "Managed Logic Inputs/1", "Managed EV Power/1");

    add_line(modelName, "Base Load/1", "Total Managed/1");
    add_line(modelName, "Managed EV Power/1", "Total Managed/2");

    % Main scope signals:
    % 1 base load, 2 unmanaged total, 3 managed total, 4 capacity limit
    add_line(modelName, "Base Load/1", "Main Scope Signals/1");
    add_line(modelName, "Total Unmanaged/1", "Main Scope Signals/2");
    add_line(modelName, "Total Managed/1", "Main Scope Signals/3");
    add_line(modelName, "Capacity Limit/1", "Main Scope Signals/4");
    add_line(modelName, "Main Scope Signals/1", "Live Scope: Load Behavior/1");

    add_line(modelName, "Total Unmanaged/1", "toWorkspace_unmanaged/1");
    add_line(modelName, "Total Managed/1", "toWorkspace_managed/1");

    save_system(modelName);
end

function plotScenario(p, s)
    figure("Name", "Site-Level Grid Behavior");
    plot(p.t_hr, p.baseLoad_kW, "LineWidth", 2); hold on;
    plot(p.t_hr, p.totalUnmanaged_kW, "LineWidth", 2);
    plot(p.t_hr, p.totalManaged_kW, "LineWidth", 2);
    plot(p.t_hr, p.capacity_kW, "--", "LineWidth", 2);
    grid on;
    xlabel("Hour of day");
    ylabel("Power (kW)");
    title("Site-Level Load Behavior: " + s.site_name + " - " + s.year);
    legend("Base building load", "Total with unmanaged charging", ...
        "Total with managed charging", "Site capacity limit", "Location","best");
end

function printSummary(p, s)
    fprintf("\nSITE-LEVEL GRID BEHAVIOR SUMMARY\n");
    fprintf("--------------------------------\n");
    fprintf("Site: %s\n", s.site_name);
    fprintf("Year/scenario: %s\n", s.year);
    fprintf("Ports from Python/right-sizing model: %.0f\n", s.ports);
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

function plotYearComparison(allProfiles, allScenarios)
    figure("Name", "Year Comparison - Managed Charging");
    hold on; grid on;

    for i = 1:numel(allProfiles)
        p = allProfiles{i};
        s = allScenarios{i};
        plot(p.t_hr, p.totalManaged_kW, "LineWidth", 2, "DisplayName", "Managed total " + s.year);
    end

    plot(allProfiles{1}.t_hr, allProfiles{1}.capacity_kW, "--", "LineWidth", 2, ...
        "DisplayName", "Capacity limit, " + allScenarios{1}.year);

    xlabel("Hour of day");
    ylabel("Power (kW)");
    title("Managed Charging Load Comparison: " + allScenarios{1}.site_name);
    legend("Location","best");
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
            s.year, s.ports, max(p.totalUnmanaged_kW), max(p.totalManaged_kW), ...
            max(p.overloadUnmanaged_kW), p.curtailedEnergy_kWh);
    end
    fprintf("\n");
end
