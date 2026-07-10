Simulink Site-Level EV Charging Grid Behavior Starter

Files:
- build_and_run_site_grid_behavior_model.m
- site_year_scenarios.csv

Goal:
Use the Python model's recommended port counts as inputs, then use Simulink to show how the site electrical load behaves over a 24-hour day for Now, 2035, and 2050.

How to run:
1. Open MATLAB.
2. Put both files in the same folder.
3. In MATLAB, make that folder the Current Folder.
4. Run:
   build_and_run_site_grid_behavior_model

What it builds:
A Simulink model named:
site_grid_behavior_ev_charging.slx

Main signals:
- Base building load
- Total load with unmanaged EV charging
- Total load with managed EV charging
- Site capacity limit

What to screenshot:
1. The Simulink model block diagram.
2. The Live Scope during simulation.
3. The MATLAB plot titled "Site-Level Load Behavior".
4. The MATLAB plot titled "Year Comparison - Managed Charging".
5. The command window summary table.

How it connects to Python:
Replace the columns in site_year_scenarios.csv with rows from your Python output:
- site_name
- recommended_ports_now
- recommended_ports_2035
- recommended_ports_2050
- spare_capacity_kw

For this starter file, ports are already written as one row per site-year scenario.
