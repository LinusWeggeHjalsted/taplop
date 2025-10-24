using UnityEngine;
using System.Collections.Generic;

public class SlamScript : MonoBehaviour, Skill
{
    private string skillName;
    private string skillType;
    private string description; 
    private float range;
    private Sprite skillSprite;
    private int cooldown;
    private int currentCooldown = 0;
    public GameObject sword;
    public SwordScript swordScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    
    public string GetSkillName()
    {
        return skillName;
    }

    public string GetSkillType()
    {
        return skillType;
    }

    public string GetDescription()
    {
        return description;
    }

    public float GetRange()
    {
        return range;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public int GetCooldown()
    {
        return cooldown;
    }

    public int CurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
        currentCooldown -= number;
    }

    public int EnemyPriority(Vector3 fromPosition, GameObject enemy)
    {
        if (currentCooldown > 0)
        {
            return -1;
        }
        Vector3 playerPosition = player.transform.position;
        float distanceToPlayer = traversableTilesScript.Distance(fromPosition, playerPosition);
        if (distanceToPlayer > range)
        {
            return -1;
        }
        else
        {
            return 2;
        }
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition)
    {
        return fromPosition;
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {

    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -range; i <= range; i++)
        {
            for (float j = -range; j <= range; j++)
            {
                if (i == 0 && j == 0)
                {
                    continue;
                }
                else
                {
                    Vector3 delta = new Vector3(i, j, 0);
                    deltas.Add(delta);
                }
            }
        }
        foreach (Vector3 delta in deltas)
        {
            Vector3 targetPosition = fromPosition + delta;
            Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
            GameObject target = null;
            if (fromPosition == player.transform.position)
            {
                if (enemyLookup.ContainsKey(targetPosition))
                {
                    target = enemyLookup[targetPosition];
                }
            }
            if (enemyLookup.ContainsKey(fromPosition))
            {
                if (targetPosition == player.transform.position)
                {
                    target = player;
                }
            }
            if (target != null)
            {
                EntityScript targetScript = target.GetComponent<EntityScript>();
                targetScript.Knockback(fromPosition, wielder, 2 * wielderScript.mainHandDamage);
                targetScript.stunDuration += 1;
            }
        }
        if (wielder == player)
        {
            turnLogicScript.hasAttacked = true;
        }
        currentCooldown = cooldown;
    }

    void Start()
    {
        skillName = "Slam";
        skillType = "Main Hand Skill";
        description = "Stun and knockback each target within range";
        cooldown = 2;
        range = 1f;
        skillSprite = Resources.Load<Sprite>("Skill Sprites/Slam");
        sword = this.transform.parent.gameObject;
        swordScript = sword.GetComponent<SwordScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        player = GameObject.Find("Player");
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
    }
}
