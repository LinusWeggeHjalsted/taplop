using UnityEngine;
using System;
using System.Collections;
using System.Collections.Generic;

public class PathNode : IComparable<PathNode>
{
    public Vector3 position;
    public PathNode parent;
    public float gCost;
    public float hCost;
    public float fCost
    {
        get { return gCost + hCost; }
    }

    public PathNode(Vector3 pos, PathNode parent = null)
    {
        this.position = pos;
        this.parent = parent;
    }

    public int CompareTo(PathNode other)
    {
        if (this.fCost < other.fCost) return -1;
        if (this.fCost > other.fCost) return 1;
        // if fCosts are equal, use position as tiebreaker to ensure uniqueness
        if (this.position.x != other.position.x)
            return this.position.x.CompareTo(other.position.x);
        if (this.position.y != other.position.y)
            return this.position.y.CompareTo(other.position.y);
        else return 0;
    }
}

public class TraversableTilesScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public Dictionary<Vector3, GameObject> tileLookup = new Dictionary<Vector3, GameObject>();
    
    public void ClearHighlights()
    {
        foreach (GameObject tileObject in tileLookup.Values)
        {
            TileScript tileScript = tileObject.GetComponent<TileScript>();
            if (tileScript.IsHighlighted)
            {
                tileScript.IsHighlighted = false;
            }
        }
    }

    public float Distance(Vector3 startPosition, Vector3 endPosition)
    {
        // diagonal movement is allowed
        float dX = Math.Abs(startPosition.x - endPosition.x);
        float dY = Math.Abs(startPosition.y - endPosition.y);
        return Math.Max(dX, dY);
    }

    public List<Vector3> ShortestPath(Vector3 startPosition, Vector3 endPosition)
    {
        PathNode startNode = new PathNode(startPosition);
        startNode.gCost = 0;

        SortedSet<PathNode> openSet = new SortedSet<PathNode>();
        Dictionary<Vector3, PathNode> openSetLookup = new Dictionary<Vector3, PathNode>();
        openSet.Add(startNode);
        openSetLookup.Add(startPosition, startNode);

        Dictionary<Vector3, PathNode> closedSet = new Dictionary<Vector3, PathNode>();

        List<Vector3> neighborDeltas = new List<Vector3>();
        for (int x = -1; x <= 1; x++)
        {
            for (int y = -1; y <= 1; y++)
            {
                if (x == 0 && y == 0)
                {
                    continue;
                }
                neighborDeltas.Add(new Vector3(x, y, 0));
            }
        }

        // start the search
        bool pathNotFound = true;
        while (pathNotFound && openSet.Count > 0)
        {
            // get lowest fCost
            PathNode focusedNode = openSet.Min;
            openSet.Remove(focusedNode);
            closedSet.Add(focusedNode.position, focusedNode);
            if (focusedNode.position == endPosition)
            {
                pathNotFound = false;
            }
            else
            {
                // add new neighbors to open set with costs calculated
                foreach (Vector3 delta in neighborDeltas)
                {
                    Vector3 neighborPosition = focusedNode.position + delta;
                    // check if we already checked this tile
                    if (closedSet.ContainsKey(neighborPosition))
                    {
                        continue;
                    }
                    // check if tile is not traversable
                    if (!tileLookup.ContainsKey(neighborPosition))
                    {
                        continue;
                    }
                    // check if tile is occupied by an enemy
                    if (enemiesScript.enemyLookup.ContainsKey(neighborPosition))
                    {
                        continue;
                    }
                    // check if tile is occupied by player (unless it's the destination)
                    if (player != null && neighborPosition == player.transform.position && neighborPosition != endPosition)
                    {
                        continue;
                    }
                    // update if neighbor has been checked already
                    if (openSetLookup.ContainsKey(neighborPosition))
                    {
                        PathNode existingNode = openSetLookup[neighborPosition];
                        float newGCost = focusedNode.gCost + Distance(focusedNode.position, neighborPosition);
                        if (newGCost < existingNode.gCost)
                        {
                            // Remove from SortedSet before updating fCost, then re-add
                            openSet.Remove(existingNode);
                            existingNode.gCost = newGCost;
                            existingNode.parent = focusedNode;
                            openSet.Add(existingNode);
                        }
                    }
                    // if not, create a new PathNode for the neighbor
                    else
                    {
                        PathNode newNeighborNode = new PathNode(neighborPosition, focusedNode);
                        newNeighborNode.gCost = focusedNode.gCost + Distance(focusedNode.position, neighborPosition);
                        newNeighborNode.hCost = Distance(neighborPosition, endPosition);
                        openSet.Add(newNeighborNode);
                        openSetLookup.Add(neighborPosition, newNeighborNode);
                    } 
                }
            }
        }

        // path found or does not exist, backtrack and return path in reverse order
        if (pathNotFound)
        {
            return null;
        }
        else
        {
            List<Vector3> foundPath = new List<Vector3>();
            Vector3 backtrackingPosition = endPosition;
            bool backtracking = true;
            while (backtracking)
            {
                if (backtrackingPosition == startPosition)
                {
                    backtracking = false;
                }
                else
                {
                    foundPath.Add(backtrackingPosition);
                    PathNode backtrackingNode = openSetLookup[backtrackingPosition];
                    backtrackingPosition = backtrackingNode.parent.position;
                }
            }
            return foundPath;
        }
    }

    public float WalkingDistance(Vector3 startPosition, Vector3 endPosition)
    {
        List<Vector3> shortestPath = ShortestPath(startPosition, endPosition);
        if (shortestPath != null)
        {
            return shortestPath.Count;
        }
        else
        {
            return float.MaxValue;
        }
    }

    IEnumerator WaitForLevelBuilderBeforePopulating()
    {
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        // populate tileLookup
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject tile = this.transform.GetChild(i).gameObject;
            tileLookup.Add(tile.transform.position, tile);
        }
        finishedBuilding = true;
    }

    void Start()
    {
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        player = GameObject.Find("Player");
        // wait for LevelBuilder to finish building
        StartCoroutine(WaitForLevelBuilderBeforePopulating());
    }
}
