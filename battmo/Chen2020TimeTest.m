%%
%Function taking multiplicative factor to run the Chen 2020 example
%Used in plotTime.m
%
%%
%% Chen model
% Include presentation of the test case (use rst format)
function [timed,t_avg]=Chen2020TimeTest(mult)
    % load MRST modules
    mrstModule add ad-core mrst-gui mpfa
    
    % We create an instance of BatteryInputParams. This class is used to initiate the battery simulator and it propagates
    % all the parameters through out the submodels.
    
    % The input parameters can be given in json format. The json file is read and used to populate the paramobj object.
    jsonstruct = parseBattmoJson('ParameterData/ParameterSets/Chen2020/chen2020_lithium_ion_battery.json');
    jsonstruct.NegativeElectrode.ActiveMaterial.SolidDiffusion.useSimplifiedDiffusionModel=false;
    jsonstruct.PositiveElectrode.ActiveMaterial.SolidDiffusion.useSimplifiedDiffusionModel=false;
    paramobj = BatteryInputParams(jsonstruct);
    
    % Some shorthands used for the sub-models
    ne    = 'NegativeElectrode';
    pe    = 'PositiveElectrode';
    am    = 'ActiveMaterial';
    sd    = 'SolidDiffusion';
    elyte = 'Electrolyte';
    
    %% We setup the battery geometry ("bare" battery with no current collector).
    gen = BareBatteryGenerator3D();
    gen.fac = mult;
    gen.nenr=20;
    gen.penr=20;
    gen = gen.applyResolutionFactors();
    % We update pamobj with grid data
    paramobj = gen.updateBatteryInputParams(paramobj);
    
    paramobj.(ne).(am).InterDiffusionCoefficient = 0;
    paramobj.(pe).(am).InterDiffusionCoefficient = 0;
    
    paramobj.(ne).(am).(sd).useSimplifiedDiffusionModel = false;
    paramobj.(pe).(am).(sd).useSimplifiedDiffusionModel = false;
    
    
    %%  The Battery model is initialized by sending paramobj to the Battery class constructor 
    
    model = Battery(paramobj);
    
    %% We fix the input current to 5A
    
    model.Control.Imax = 5;
    
    %% We setup the schedule 
    % We use different time step for the activation phase (small time steps) and the following discharging phase
    % We start with rampup time steps to go through the activation phase 
    
    fac   = 2; 
    total = 1.4*hour; 
    n     = 100; 
    dt0   = total*1e-6; 
    times = getTimeSteps(dt0, n, total, fac); 
    dt    = diff(times);
    dt    = dt(1 : end);
    step  = struct('val', dt, 'control', ones(size(dt)));
    
    % We set up a stopping function. Here, the simulation will stop if the output voltage reach a value smaller than 2. This
    % stopping function will not be triggered in this case as we switch to voltage control when E=3.6 (see value of inputE
    % below).
    pe = 'PositiveElectrode';
    cc = 'CurrentCollector';
    
    tup = 0.1; % rampup value for the current function, see rampupSwitchControl
    srcfunc = @(time, I, E) rampupSwitchControl(time, tup, I, E, ...
                                                model.Control.Imax, ...
                                                model.Control.lowerCutoffVoltage);
    % we setup the control by assigning a source and stop function.
    control = struct('src', srcfunc, 'IEswitch', true);
    
    % This control is used to set up the schedule
    schedule = struct('control', control, 'step', step); 
    
    %%  We setup the initial state
    
    nc = model.G.cells.num;
    T = model.initT;
    initstate.ThermalModel.T = T*ones(nc, 1);
    
    bat = model;
    elyte = 'Electrolyte';
    ne    = 'NegativeElectrode';
    pe    = 'PositiveElectrode';
    itf   = 'Interface';
    sd    = 'SolidDiffusion';
    ctrl  = 'Control';
    
    initstate = model.updateTemperature(initstate);
    
    % we setup negative electrode initial state
    nitf = bat.(ne).(am).(itf); 
    
    % We bypass the solid diffusion equation to set directly the particle surface concentration
    c = 29866.0;
    if model.(ne).(am).useSimplifiedDiffusionModel
        nenp = model.(ne).(am).G.cells.num;
        initstate.(ne).(am).c = c*ones(nenp, 1);
    else
        nenr = model.(ne).(am).(sd).N;
        nenp = model.(ne).(am).(sd).np;
        initstate.(ne).(am).(sd).c = c*ones(nenr*nenp, 1);
    end
    initstate.(ne).(am).(sd).cSurface = c*ones(nenp, 1);
    
    initstate.(ne).(am) = model.(ne).(am).updateConcentrations(initstate.(ne).(am));
    initstate.(ne).(am).(itf) = nitf.updateOCP(initstate.(ne).(am).(itf));
    
    OCP = initstate.(ne).(am).(itf).OCP;
    ref = OCP(1);
    
    initstate.(ne).(am).phi = OCP - ref;
    
    % we setup positive electrode initial state
    
    pitf = bat.(pe).(am).(itf); 
    
    c = 17038.0;
    
    if model.(pe).(am).useSimplifiedDiffusionModel
        penp = model.(pe).(am).G.cells.num;
        initstate.(pe).(am).c = c*ones(penp, 1);
    else
        penr = model.(pe).(am).(sd).N;
        penp = model.(pe).(am).(sd).np;
        initstate.(pe).(am).(sd).c = c*ones(penr*penp, 1);
    end
    initstate.(pe).(am).(sd).cSurface = c*ones(penp, 1);
    
    initstate.(pe).(am) = model.(pe).(am).updateConcentrations(initstate.(pe).(am));
    initstate.(pe).(am).(itf) = pitf.updateOCP(initstate.(pe).(am).(itf));
    
    OCP = initstate.(pe).(am).(itf).OCP;
    
    initstate.(pe).(am).phi = OCP - ref;
    
    initstate.(elyte).phi = zeros(bat.(elyte).G.cells.num, 1) - ref;
    initstate.(elyte).c = 1000*ones(bat.(elyte).G.cells.num, 1);
    
    % setup initial positive electrode external coupling values
    
    initstate.(ctrl).E = OCP(1) - ref;
    initstate.(ctrl).I = 0;
    initstate.(ctrl).ctrlType = 'constantCurrent';
    
    % Setup nonlinear solver 
    nls = NonLinearSolver(); 
    % Change default maximum iteration number in nonlinear solver
    nls.maxIterations = 10; 
    % Change default behavior of nonlinear solver, in case of error
    nls.errorOnFailure = false; 
    % Change default tolerance for nonlinear solver
    model.nonlinearTolerance = 1e-5; 
    % Set verbosity
    model.verbose = false;
    
    model.AutoDiffBackend= AutoDiffBackend();
    
    % Run simulation
    t_avg=0
    tstart=tic;
    [wellSols, states, report] = simulateScheduleAD(initstate, model, schedule, 'OutputMinisteps', true, 'NonLinearSolver', nls); 
    timed=toc(tstart);
    for j=1:10
        tstart=tic;
        [wellSols, states, report] = simulateScheduleAD(initstate, model, schedule, 'OutputMinisteps', true, 'NonLinearSolver', nls); 
        t_avg=t_avg + toc(tstart);
    end
    t_avg=t_avg/10

end

%{
Copyright 2021-2022 SINTEF Industry, Sustainable Energy Technology
and SINTEF Digital, Mathematics & Cybernetics.

This file is part of The Battery Modeling Toolbox BattMo

BattMo is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

BattMo is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with BattMo.  If not, see <http://www.gnu.org/licenses/>.
%}
