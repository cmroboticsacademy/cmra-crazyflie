#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
#     ||          ____  _ __
#  +------+      / __ )(_) /_______________ _____  ___
#  | 0xBC |     / __  / / __/ ___/ ___/ __ `/_  / / _ \
#  +------+    / /_/ / / /_/ /__/ /  / /_/ / / /_/  __/
#   ||  ||    /_____/_/\__/\___/_/   \__,_/ /___/\___/
#
#  Copyright (C) 2019 Bitcraze AB
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License
#  as published by the Free Software Foundation; either version 2
#  of the License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

# Modified by Carnegie Mellon Robotics Academy on 12/16/2024
"""
Simple example of a waypoint choreography using the High level
commander.

The drone takes off and flies a to a waypoint before landing.
The take-of is relative to the start position but the Goto are absolute when using the field_relative argument.
The sequence contains a list of commands to be executed at each step.

This example is intended to work with any absolute positioning system.
It aims at documenting how to use the High Level Commander together with
the Swarm class to achieve synchronous sequences.
"""
import threading
import time
from collections import namedtuple
from queue import Queue

import cflib.crtp
from cflib.crazyflie.swarm import CachedCfFactory
from cflib.crazyflie.swarm import Swarm
from cflib.crazyflie.log import LogConfig
from cflib.crazyflie.syncLogger import SyncLogger



# Define the URI of the Crazyflie (e.g., replace with your specific radio addresses)
uris = [
    'radio://0/80/2M/E7E7E7E7E0',  # cf_id 0, startup position [anywhere]
]

starting_positions = [None] * len(uris)
starting_positions_lock = threading.Lock()

# Possible commands, all times are in seconds
Arm = namedtuple('Arm', [])
Takeoff = namedtuple('Takeoff', ['height', 'time'])
Land = namedtuple('Land', ['time'])
Goto = namedtuple('Goto', ['x', 'y', 'z', 'time', 'relative'])
# RGB [0-255], Intensity [0.0-1.0]
Ring = namedtuple('Ring', ['r', 'g', 'b', 'intensity', 'time'])
# Reserved for the control loop, do not use in sequence
Quit = namedtuple('Quit', [])
Gohome = namedtuple('Gohome', ['time'])



# variables for controlling relative vs absolute movements. DO NOT TOUCH
field_relative = False
drone_relative = True

# Time for one step in second
STEP_TIME = 2

sequence = [
    # Step, CF_id,  action
    (0,    0,      Arm()),

    (1,    0,      Takeoff(1.0, STEP_TIME)),

    (2,    0,      Goto(1,  1,  1, STEP_TIME, field_relative)),
    
    (3,    0,      Gohome(STEP_TIME)),
    
	(4,    0,      Land(STEP_TIME)),
    
]


def activate_mellinger_controller(scf, use_mellinger):
    controller = 1
    if use_mellinger:
        controller = 2
    scf.cf.param.set_value('stabilizer.controller', str(controller))

def verify_loco_deck(scf):
    """
    Verifies if the Loco Positioning Deck is attached to the given drone.
    """
    loco_connected = scf.cf.param.get_value('deck.bcLoco')
    if loco_connected == '1':
        print(f"Loco Positioning Deck is connected on {scf.cf.link_uri}")
        return True
    else:
        print(f"Loco Positioning Deck is NOT connected on {scf.cf.link_uri}")
        return False


def verify_loco_deck_swarm(swarm):
    """
    Verifies if the Loco Positioning Deck is connected to each drone in the swarm.
    """
    all_connected = True

    def check_deck(scf):
        nonlocal all_connected
        if not verify_loco_deck(scf):
            all_connected = False

    swarm.parallel_safe(check_deck)
    return all_connected

def wait_for_position_estimator(scf):
    print('Waiting for estimator to find position...')

    log_config = LogConfig(name='Kalman Variance', period_in_ms=500)
    log_config.add_variable('kalman.varPX', 'float')
    log_config.add_variable('kalman.varPY', 'float')
    log_config.add_variable('kalman.varPZ', 'float')

    var_y_history = [1000] * 10
    var_x_history = [1000] * 10
    var_z_history = [1000] * 10

    threshold = 0.001

    with SyncLogger(scf, log_config) as logger:
        for log_entry in logger:
            data = log_entry[1]

            var_x_history.append(data['kalman.varPX'])
            var_x_history.pop(0)
            var_y_history.append(data['kalman.varPY'])
            var_y_history.pop(0)
            var_z_history.append(data['kalman.varPZ'])
            var_z_history.pop(0)

            min_x = min(var_x_history)
            max_x = max(var_x_history)
            min_y = min(var_y_history)
            max_y = max(var_y_history)
            min_z = min(var_z_history)
            max_z = max(var_z_history)

            if (max_x - min_x) < threshold and (
                    max_y - min_y) < threshold and (
                    max_z - min_z) < threshold:
                break

def reset_estimator(scf):
    cf = scf.cf
    cf.param.set_value('kalman.resetEstimation', '1')
    time.sleep(0.1)
    cf.param.set_value('kalman.resetEstimation', '0')

    wait_for_position_estimator(scf)
def save_initial_state(scf):
    
    log_config = LogConfig(name='Initial State', period_in_ms=500)
    log_config.add_variable('kalman.stateX', 'float')
    log_config.add_variable('kalman.stateY', 'float')
    log_config.add_variable('kalman.stateZ', 'float')

    with SyncLogger(scf, log_config) as logger:
        for log_entry in logger:
            data = log_entry[1]
            pos = (data['kalman.stateX'], data['kalman.stateY'], data['kalman.stateZ'])
            idx = uris.index(scf.cf.link_uri)
            with starting_positions_lock:
                starting_positions[idx] = pos
            print(f"Initial state saved: (idx {idx}): {pos}")
            break  # Exit after saving the first reading

def position_callback(timestamp, data, logconf):
    x = data['kalman.stateX']
    y = data['kalman.stateY']
    z = data['kalman.stateZ']
    print('pos: ({}, {}, {})'.format(x, y, z))

def start_position_printing(scf):
    log_conf = LogConfig(name='Position', period_in_ms=500)
    log_conf.add_variable('kalman.stateX', 'float')
    log_conf.add_variable('kalman.stateY', 'float')
    log_conf.add_variable('kalman.stateZ', 'float')

    scf.cf.log.add_config(log_conf)
    log_conf.data_received_cb.add_callback(position_callback)
    log_conf.start()


def arm(scf):
    scf.cf.platform.send_arming_request(True)
    time.sleep(1.0)


def set_ring_color(cf, r, g, b, intensity, time):
    cf.param.set_value('ring.fadeTime', str(time))

    r *= intensity
    g *= intensity
    b *= intensity

    color = (int(r) << 16) | (int(g) << 8) | int(b)

    cf.param.set_value('ring.fadeColor', str(color))


def crazyflie_control(scf):
    cf = scf.cf
    control = controlQueues[uris.index(cf.link_uri)]

    activate_mellinger_controller(scf, False)

    commander = scf.cf.high_level_commander

    # Set fade to color effect and reset to Led-ring OFF
    set_ring_color(cf, 0, 0, 0, 0, 0)
    cf.param.set_value('ring.effect', '14')
    while True:
        command = control.get()
        if type(command) is Quit:
            return
        elif type(command) is Arm:
            arm(scf)
        elif type(command) is Takeoff:
            commander.takeoff(command.height, command.time)
        elif type(command) is Land:
            commander.land(0.0, command.time)
        elif type(command) is Goto:
            commander.go_to(command.x, command.y, command.z, 0, command.time, command.relative)
        elif type(command) is Ring:
            set_ring_color(cf, command.r, command.g, command.b,
                           command.intensity, command.time)
            pass
        elif type(command) is Gohome:
            idx = uris.index(cf.link_uri)
            with starting_positions_lock:
                home = starting_positions[idx]
            if home is None:
                print(f"NO HOME FOUND {cf.link_uri}")
                continue
            
            commander.go_to(home[0], home[1], home[2] +.5, 0, command.time, field_relative)
        else:
            print('Warning! unknown command {} for uri {}'.format(command,
                                                                  cf.uri))


def control_thread():
    pointer = 0
    step = 0
    stop = False

    while not stop:
        print('Step {}:'.format(step))
        while sequence[pointer][0] <= step:
            cf_id = sequence[pointer][1]
            command = sequence[pointer][2]

            print(' - Running: {} on {}'.format(command, cf_id))
            controlQueues[cf_id].put(command)
            pointer += 1

            if pointer >= len(sequence):
                print('Reaching the end of the sequence, stopping!')
                stop = True
                break

        step += 1
        time.sleep(STEP_TIME)

    for ctrl in controlQueues:
        ctrl.put(Quit())


if __name__ == '__main__':
    controlQueues = [Queue() for _ in range(len(uris))]

    cflib.crtp.init_drivers()
    factory = CachedCfFactory(rw_cache='./cache')
    with Swarm(uris, factory=factory) as swarm:
        print("Verifying Loco Positioning Decks...")
        if not verify_loco_deck_swarm(swarm):
            print("One or more drones do not have the Loco Deck connected. Exiting...")
            exit(1)
        print("All drones have Loco Decks connected.")

        
        print("Resetting Estimators")
        swarm.parallel_safe(reset_estimator)
        print("Estimators Reset")
        swarm.parallel_safe(save_initial_state)
        print("Starting points:", starting_positions)
        
        input("Ready to Fly, press ENTER to continue")

        print('Starting sequence!')

        threading.Thread(target=control_thread).start()

        swarm.parallel_safe(crazyflie_control)

        time.sleep(1)
        print('Sequence Complete')