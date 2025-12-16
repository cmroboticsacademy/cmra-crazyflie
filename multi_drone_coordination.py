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
Simple example of a synchronized swarm choreography using the High level
commander.

The swarm takes off and flies a synchronous choreography before landing.
The take-of is relative to the start position but the Goto are only 
absolute when using the field_relative argument.
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



# Define the URI of the Crazyflie (e.g., replace with your specific radio addresses)
uris = [
    'radio://0/80/2M/E7E7E7E7E7',  # cf_id 0, startup position (1,1)
    'radio://0/80/2M/E7E7E7E7E8',  # cf_id 1, startup position (.5,1)
    'radio://0/80/2M/E7E7E7E7E9',  # cf_id 3, startup position (1.5,1)
    # Add more URIs if you want more copters in the swarm
]


# Possible commands, all times are in seconds
Arm = namedtuple('Arm', [])
Takeoff = namedtuple('Takeoff', ['height', 'time'])
Land = namedtuple('Land', ['time'])
Goto = namedtuple('Goto', ['x', 'y', 'z', 'time', 'relative'])
# RGB [0-255], Intensity [0.0-1.0]
Ring = namedtuple('Ring', ['r', 'g', 'b', 'intensity', 'time'])
# Reserved for the control loop, do not use in sequence
Quit = namedtuple('Quit', [])


# variables for controlling relative vs absolute movements. DO NOT TOUCH
field_relative = False
drone_relative = True

# Time for one step in second
STEP_TIME = 2

# size of box in meters
box_size = 1

sequence = [
    # Step, CF_id,  action
    (0,    0,      Arm()),
    (0,    1,      Arm()),
    (0,    2,      Arm()),

    (1,    0,      Takeoff(1.0, 2)),
    (1,    1,      Takeoff(1.0, 2)),
    (1,    2,      Takeoff(1.0, 2)),
    
    (2,    0,      Goto(1,  1,   1, 2, field_relative)),
    (2,    1,      Goto(.5, 1,   1, 2, field_relative)),
    (2,    2,      Goto(1.5,  1,   1, 2, field_relative)),

    (2,    0,      Goto(box_size,  0,   0, 2, drone_relative)),
    (2,    1,      Goto(box_size,  0,   0, 2, drone_relative)),
    (2,    2,      Goto(box_size,  0,   0, 2, drone_relative)),

   	(3,    0,      Goto(0, box_size,   0, 2, drone_relative)),
    (3,    1,      Goto(0, box_size,   0, 2, drone_relative)),
    (3,    2,      Goto(0, box_size,   0, 2, drone_relative)),
	
	(4,    0,      Goto(-box_size,  0,   0, 2, drone_relative)),
    (4,    1,      Goto(-box_size, 0,   0, 2, drone_relative)),
    (4,    2,      Goto(-box_size, 0,   0, 2, drone_relative)),
    
	(5,    0,      Goto(0, -box_size,   0, 2, drone_relative)),
    (5,    1,      Goto(0, -box_size,   0, 2, drone_relative)),
    (5,    2,      Goto(0, -box_size,   0, 2, drone_relative)),
    
	(6,    0,      Land(2)),
    (6,    1,      Land(2)),
    (6,    2,      Land(2)),

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
        swarm.reset_estimators()
        print("Estimators Reset")
        
        input("Ready to Fly, press ENTER to continue")

        print('Starting sequence!')

        threading.Thread(target=control_thread).start()

        swarm.parallel_safe(crazyflie_control)

        time.sleep(1)
        print('Sequence Complete')