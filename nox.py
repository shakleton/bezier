# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from __future__ import print_function

import os
import sys

import nox
import nox.command


BASE_DEPS = (
    'mock >= 1.3.0',
    'numpy',
    'pytest',
)
NOX_DIR = os.path.abspath(os.path.dirname(__file__))
DOCS_DEPS = (
    '--requirement',
    os.path.join(NOX_DIR, 'docs', 'requirements.txt'),
)
DOCS_INTERP = 'python3.6'


def get_path(*names):
    return os.path.join(NOX_DIR, *names)


@nox.session
@nox.parametrize('python_version', ['2.7', '3.5', '3.6'])
def unit_tests(session, python_version):
    session.interpreter = 'python{}'.format(python_version)

    # Install all test dependencies.
    local_deps = BASE_DEPS + ('scipy',)
    session.install(*local_deps)
    # Install this package.
    session.install('.')

    # Run py.test against the unit tests.
    run_args = ['py.test'] + session.posargs + [get_path('tests')]
    session.run(*run_args)


@nox.session
def cover(session):
    session.interpreter = 'python2.7'

    # Install all test dependencies.
    local_deps = BASE_DEPS + ('scipy', 'pytest-cov', 'coverage')
    session.install(*local_deps)
    # Install this package.
    session.install('.')

    # Run py.test with coverage against the unit tests.
    run_args = ['py.test', '--cov=bezier', '--cov=tests']
    run_args += session.posargs
    run_args += [
        get_path('tests'),
        get_path('functional_tests', 'test_segment_box.py'),
    ]
    session.run(*run_args)


@nox.session
def functional(session):
    session.interpreter = 'python2.7'

    # Install all test dependencies.
    session.install(*BASE_DEPS)
    # Install this package.
    session.install('.')

    # Run py.test against the functional tests.
    run_args = ['py.test'] + session.posargs + [get_path('functional_tests')]
    session.run(*run_args)


@nox.session
def docs(session):
    session.interpreter = DOCS_INTERP

    # Install all dependencies.
    session.install(*DOCS_DEPS)
    # Install this package.
    session.install('.')

    # Run the script for building docs.
    command = get_path('scripts', 'build_docs.sh')
    session.run(command)


def get_doctest_args(session):
    run_args = [
        'sphinx-build', '-W',
        '-b', 'doctest',
        '-d', get_path('docs', 'build', 'doctrees'),
        get_path('docs'),
        get_path('docs', 'build', 'doctest'),
    ]
    run_args += session.posargs
    return run_args


@nox.session
def doctest(session):
    session.interpreter = DOCS_INTERP
    if 'NO_IMAGES' not in os.environ:
        reason = 'NO_IMAGES=True must be set'
        print(reason, file=sys.stderr)
        raise nox.command.CommandFailed(reason=reason)

    # Install all dependencies.
    session.install(*DOCS_DEPS)
    # Install this package.
    session.install('.')

    # Run the script for building docs and running doctests.
    run_args = get_doctest_args(session)
    session.run(*run_args)
