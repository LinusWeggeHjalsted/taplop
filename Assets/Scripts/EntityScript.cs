using UnityEngine;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

public class EntityScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public bool levelBuilderLoaded = false;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject player;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject gear;
    public GearScript gearScript;
    public Transform mainHand;
    public Transform offHand;
    public GameObject mainHandWeapon;
    public GameObject offHandWeapon;
    public GameObject healthBar;
    public SpriteRenderer healthBarRenderer;
    public Sprite[] healthBarStates = new Sprite[8];
    public Sprite hitSprite;
    public Sprite aggroSprite;

    public string currentBuildTemplate = "00000000";
    public int maxHealth = 10;
    private int currentHealth;
    public int CurrentHealth
    {
        get
        {
            return currentHealth;
        }
        set
        {
            if (value > maxHealth)
            {
                currentHealth = maxHealth;
            }
            else
            {
                currentHealth = value;
            }
            DisplayHealth();
            Debug.Log(name + " health was updated to " + this.currentHealth.ToString());
        }
    }
    public int armor;
    public int speed;
    public int aggroRange;
    public Vector3 previousPosition = new Vector3();
    public int unlockedSkills;
    public List<GameObject> equippedSkills = new List<GameObject>();
    private bool isActive = false;
    public bool IsActive
    {
        get
        {
            return isActive;
        }
        set
        {
            if (value == true)
            {
                DisplayAggro();
            }
            isActive = value;
        }
    }
    public float minRange
    {
        get
        {
            List<float> skillRanges = new List<float>();
            for (int i = 0; i < equippedSkills.Count; i++)
            {
                GameObject skill = equippedSkills[i];
                Skill skillScript = skill.GetComponent<Skill>();
                float skillRange = skillScript.GetRange();
                if (skillRange > 0)
                {
                    skillRanges.Add(skillScript.GetRange());
                }
            }
            return skillRanges.Min();
        }
    }
    public int reflectDuration = 0;
   
    public void DisplayAggro()
    {
        GameObject aggroObject = new GameObject("Aggro Sprite Object");
        aggroObject.transform.parent = this.transform;
        aggroObject.transform.localPosition = new Vector3(0, 1.125f, 0);
        SpriteRenderer aggroRenderer = aggroObject.AddComponent<SpriteRenderer>();
        aggroRenderer.sortingLayerName = "Effects";
        aggroRenderer.sortingOrder = 2;
        aggroRenderer.sprite = aggroSprite;
        Destroy(aggroObject, 0.5f);
    }

    public void DisplayHit()
    {
        GameObject hitObject = new GameObject("Hit Sprite Object");
        hitObject.transform.parent = this.transform;
        hitObject.transform.localPosition = new Vector3(0, 0.375f, 0);
        SpriteRenderer hitRenderer = hitObject.AddComponent<SpriteRenderer>();
        hitRenderer.sortingLayerName = "Effects";
        hitRenderer.sortingOrder = 2;
        hitRenderer.sprite = hitSprite;
        Destroy(hitObject, 0.25f);
    }

    public void DisplayHealth()
    {   if (!levelBuilderLoaded)
        {
            return;
        }
        if (healthBar == null)
        {
            healthBar = new GameObject("Entity Health Bar");
            healthBar.transform.parent = this.transform;
            healthBar.transform.localPosition = new Vector3(0, 1.5f, 0);
            healthBarRenderer = healthBar.AddComponent<SpriteRenderer>();
            healthBarRenderer.sortingLayerName = "Effects";
            healthBarRenderer.sortingOrder = 2;
        }
        Sprite healthBarSprite = null;
        float healthPercentage = (float)currentHealth / (float)maxHealth;
        switch (healthPercentage)
        {
            case < 0.125f:
                healthBarSprite = healthBarStates[0];
                break;
            case >= 0.125f and < 0.250f:
                healthBarSprite = healthBarStates[1];
                break;
            case >= 0.250f and < 0.375f:
                healthBarSprite = healthBarStates[2];
                break;
            case >= 0.375f and < 0.500f:
                healthBarSprite = healthBarStates[3];
                break;
            case >= 0.500f and < 0.625f:
                healthBarSprite = healthBarStates[4];
                break;
            case >= 0.625f and < 0.750f:
                healthBarSprite = healthBarStates[5];
                break;
            case >= 0.750f and < 0.875f:
                healthBarSprite = healthBarStates[6];
                break;
            case >= 0.875f and < 1:
                healthBarSprite = healthBarStates[7];
                break;
            case >= 1:
                healthBarSprite = healthBarStates[8];
                break;
        }
        if (healthBarSprite != null)
        {
            healthBarRenderer.sprite = healthBarSprite;
        }
    }

    public void MoveTo(Vector3 targetPosition)
    {
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        GameObject targetTile = tileLookup[targetPosition];
        TileScript targetTileScript = targetTile.GetComponent<TileScript>();
        if (targetTileScript.isOccupied) 
        {
            Debug.Log("tried to move to an occupied tile");
            return;
        }
        Vector3 currentPosition = this.transform.position;
        GameObject currentTile = tileLookup[currentPosition];
        TileScript currentTileScript = currentTile.GetComponent<TileScript>();
        targetTileScript.isOccupied = true;
        currentTileScript.isOccupied = false;
        previousPosition = currentPosition;
        if (enemiesScript.enemyLookup.ContainsKey(currentPosition))
        {
            enemiesScript.EnemyMoved(currentPosition, targetPosition);
        }
        this.transform.position = targetPosition;
        if (targetPosition == player.transform.position)
        {
            enemiesScript.UpdateAggro();
        }
    }

    public void IncomingDamage(int damage, GameObject attacker)
    {
        DisplayHit();
        if (!IsActive)
        {
            IsActive = true;
        }
        if (reflectDuration > 0)
        {
            EntityScript attackerScript = attacker.GetComponent<EntityScript>();
            attackerScript.IncomingDamage(damage, attacker);
            return;
        }
        // to-do - figure out a good damage calculation
        int actualDamage = damage - armor;
        if (actualDamage < 0)
        {
            return;
        }
        else
        {
            CurrentHealth -= actualDamage;
        }
    }

    public void ReduceCooldowns(int number)
    {
        foreach (GameObject skill in equippedSkills)
        {
            Skill skillScript = skill.GetComponent<Skill>();
            skillScript.ReduceCooldown(number);
        }
    }

    public void ReduceEffectDurations(int number)
    {
        reflectDuration -= number;
        if (reflectDuration < 0)
        {
            reflectDuration = 0;
        }
    }

    IEnumerator WaitForGearBeforePopulating()
    {
        while (!gearScript.finishedBuilding)
        {
            yield return null;
        }
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        mainHand = gear.transform.Find("Main Hand");
        offHand = gear.transform.Find("Off Hand");
        mainHandWeapon = mainHand.GetChild(0).gameObject;
        offHandWeapon = offHand.GetChild(0).gameObject;
        GameObject skill1 = mainHandWeapon.transform.GetChild(0).gameObject;
        GameObject skill2 = mainHandWeapon.transform.GetChild(1).gameObject;
        GameObject skill3 = offHandWeapon.transform.GetChild(0).gameObject;
        equippedSkills.Add(skill1);
        equippedSkills.Add(skill2);
        equippedSkills.Add(skill3);
        finishedBuilding = true;
    }

    void Start()
    {
        Debug.Log("Hello World - I'm " + this.name);
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        levelBuilderLoaded = true;
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        player = GameObject.Find("Player");
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        gear = this.transform.Find("Gear").gameObject;
        gearScript = gear.GetComponent<GearScript>();
        hitSprite = Resources.Load<Sprite>("Hit");
        aggroSprite = Resources.Load<Sprite>("EnemyAggro");
        healthBarStates = Resources.LoadAll<Sprite>("EntityHealthBars");
        CurrentHealth = maxHealth;
        StartCoroutine(WaitForGearBeforePopulating());
    }
}
