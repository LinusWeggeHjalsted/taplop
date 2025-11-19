using UnityEngine;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

public class EntityScript : MonoBehaviour, PlayerCharacterScript
{
    private bool _finishedBuilding = false;
    public bool finishedBuilding
    {
        get
        {
            return _finishedBuilding;
        }
        set
        {
            _finishedBuilding = value;
        }
    }
    public GameObject missionLogic;
    public MissionLogicScript missionLogicScript;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public bool levelBuilderLoaded = false;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject player;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject drops;
    public DropsScript dropsScript;
    public SpriteRenderer spriteRenderer;
    private Sprite[] spriteSheet = new Sprite[2];
    public Sprite[] SpriteSheet
    {
        get
        {
            return spriteSheet;
        }
        set
        {
            // update SpriteRenderer
            spriteSheet = value;
            spriteRenderer.sprite = spriteSheet[0];
        }
    }
    public GameObject gear;
    public GearScript gearScript;

    private Transform _mainHand;
    private Transform _offHand;
    private Transform _hands;
    private Transform _body;
    private Transform _feet;
    private Transform _inventory;
    private int _inventorySize;
    private Transform _utilitySkills;
    private int _utilitySkillSlots;

    public Transform mainHand { get { return _mainHand; } }
    public Transform offHand { get { return _offHand; } }
    public Transform hands { get { return _hands; } }
    public Transform body { get { return _body; } }
    public Transform feet { get { return _feet; } }
    public Transform inventory { get { return _inventory; } }
    public int inventorySize { get { return _inventorySize; } }
    public Transform utilitySkills { get { return _utilitySkills; } }
    public int utilitySkillSlots 
    {
        get
        {
            return _utilitySkillSlots;
        }
        set
        {
            _utilitySkillSlots = value;
        }
    }

    public GameObject mainHandWeapon
    {
        get
        {
            if (mainHand.childCount == 0) return null;
            return mainHand.GetChild(0).gameObject;
        }
    }
    public GameObject offHandWeapon
    {
        get
        {
            if (offHand.childCount == 0) return null;
            return offHand.GetChild(0).gameObject;
        }
    }
    public GameObject gloves
    {
        get
        {
            if (hands.childCount == 0) return null;
            return hands.GetChild(0).gameObject;
        }
    }
    public GameObject coat
    {
        get
        {
            if (body.childCount == 0) return null;
            return body.GetChild(0).gameObject;
        }
    }
    public GameObject boots
    {
        get
        {
            if (feet.childCount == 0) return null;
            return feet.GetChild(0).gameObject;
        }
    }
    public GameObject[] inventoryItems
    {
        get
        {
            GameObject[] itemArray = new GameObject[inventorySize];
            for (int i = 0; i < inventory.childCount; i++)
            {
                if (i < inventorySize)
                {
                    itemArray[i] = inventory.GetChild(i).gameObject;
                }
                else
                {
                    Debug.LogError("entity has more items in inventory than inventorySize " + inventorySize.ToString() + " allows");
                }
            }
            return itemArray;
        }
    }
    public GameObject healthBar;
    public SpriteRenderer healthBarRenderer;
    public Sprite[] healthBarStates = new Sprite[8];
    public Sprite hitSprite;
    public Sprite aggroSprite;

    public string currentBuildTemplate = "00000000";
    private int maxHealth;
    public int MaxHealth
    {
        get
        {
            int coatHealth = 0;
            if (coat != null)
            {
                CoatScript coatScript = coat.GetComponent<CoatScript>();
                coatHealth = coatScript.healthBonus;
            }
            return maxHealth + coatHealth;
        }
        set
        {
            maxHealth = value;
        }
    }
    private int currentHealth;
    public int CurrentHealth
    {
        get
        {
            return currentHealth;
        }
        set
        {
            if (value > MaxHealth)
            {
                currentHealth = MaxHealth;
            }
            else
            {
                currentHealth = value;
            }
            DisplayHealth();
            if (this.gameObject == player)
            {
                GameObject playerHealthBar = GameObject.Find("Player Health Bar");
                PlayerHealthBarScript playerHealthBarScript = playerHealthBar.GetComponent<PlayerHealthBarScript>();
                playerHealthBarScript.UpdateHealthBar();
            }
        }
    }
    private int armor;
    public int Armor
    {
        get
        {
            int coatArmor = 0;
            if (coat != null)
            {
                CoatScript coatScript = coat.GetComponent<CoatScript>();
                coatArmor = coatScript.armorBonus;
            }
            int glovesArmor = 0;
            if (gloves != null)
            {
                GlovesScript glovesScript = gloves.GetComponent<GlovesScript>();
                glovesArmor = glovesScript.armorBonus;
            }
            int bootsArmor = 0;
            if (boots != null)
            {
                BootsScript bootsScript = boots.GetComponent<BootsScript>();
                bootsArmor = bootsScript.armorBonus;
            }
            return armor + coatArmor + glovesArmor + bootsArmor;
        }
        set
        {
            armor = value;
        }
    }
    private int speed = 1;
    public int Speed
    {
        get
        {
            int bootsSpeed = 0;
            if (boots != null)
            {
                BootsScript bootsScript = boots.GetComponent<BootsScript>();
                bootsSpeed = bootsScript.speedBonus;
            }
            return speed + bootsSpeed;
        }
        set
        {
            speed = value;
        }
    }
    public int mainHandDamage
    {
        get
        {
            int mainHandWeaponDamage = 0;
            if (mainHandWeapon != null)
            {
                WeaponScript mainHandWeaponScript = mainHandWeapon.GetComponent<WeaponScript>();
                mainHandWeaponDamage = mainHandWeaponScript.GetDamage();
            }
            int glovesDamage = 0;
            if (gloves != null)
            {
                GlovesScript glovesScript = gloves.GetComponent<GlovesScript>();
                glovesDamage = glovesScript.damageBonus;
            }
            return mainHandWeaponDamage + glovesDamage;
        }
    }
    public int offHandDamage
    {
        get
        {
            int offHandWeaponDamage = 0;
            if (offHandWeapon != null)
            {
                WeaponScript offHandWeaponScript = offHandWeapon.GetComponent<WeaponScript>();
                offHandWeaponDamage = offHandWeaponScript.GetDamage();
            }
            int glovesDamage = 0;
            if (gloves != null)
            {
                GlovesScript glovesScript = gloves.GetComponent<GlovesScript>();
                glovesDamage = glovesScript.damageBonus;
            }
            return offHandWeaponDamage + glovesDamage;
        }
    }
    public int aggroRange;
    public Vector3 previousPosition = new Vector3();
    public GameObject[] equippedSkills
    {
        get
        {
            GameObject[] skillArray = new GameObject[8];
            if (mainHandWeapon != null)
            {
                WeaponScript mainHandWeaponScript = mainHandWeapon.GetComponent<WeaponScript>();
                skillArray[0] = mainHandWeaponScript.FirstSkill();
                skillArray[1] = mainHandWeaponScript.SecondSkill();
            }
            if (offHandWeapon != null)
            {
                WeaponScript offHandWeaponScript = offHandWeapon.GetComponent<WeaponScript>();
                skillArray[2] = offHandWeaponScript.ThirdSkill();
            }
            if (utilitySkills.childCount > 0)
            {
                for (int i = 0; i < utilitySkills.childCount; i++)
                {
                    if (i < utilitySkillSlots)
                    {
                        skillArray[i + 3] = utilitySkills.GetChild(i).gameObject;
                    }
                }
            }
            return skillArray;
        }
    }
    private bool isActive = false;
    public bool IsActive
    {
        get
        {
            return isActive;
        }
        set
        {
            Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
            if (value == true && enemyLookup.ContainsKey(this.transform.position))
            {
                if (!enemiesScript.activeEnemyLookup.ContainsKey(this.transform.position))
                {
                    DisplayAggro();
                    enemiesScript.activeEnemyLookup.Add(this.transform.position, this.gameObject);
                }
            }
            isActive = value;
        }
    }
    public float minRange
    {
        get
        {
            List<float> skillRanges = new List<float>();
            for (int i = 0; i < equippedSkills.Length; i++)
            {
                GameObject skill = equippedSkills[i];
                if (skill != null)
                {
                    Skill skillScript = skill.GetComponent<Skill>();
                    float skillRange = skillScript.GetRange();
                    if (skillRange > 0)
                    {
                        skillRanges.Add(skillScript.GetRange());
                    }
                }
            }
            return skillRanges.Min();
        }
    }
    public int stunDuration = 0;
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
        Destroy(hitObject, 0.125f);
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
        // flip sprite if moving left, unflip if moving right
        Vector3 currentPosition = this.transform.position;
        float xDif = targetPosition.x - currentPosition.x;
        if (xDif < 0)
        {
            spriteRenderer.sprite = SpriteSheet[1];
        }
        if (xDif > 0)
        {
            spriteRenderer.sprite = SpriteSheet[0];
        }
        GameObject currentTile = tileLookup[currentPosition];
        TileScript currentTileScript = currentTile.GetComponent<TileScript>();
        targetTileScript.isOccupied = true;
        currentTileScript.isOccupied = false;
        previousPosition = currentPosition;
        // update enemy lookups
        if (enemiesScript.enemyLookup.ContainsKey(currentPosition))
        {
            enemiesScript.EnemyMoved(currentPosition, targetPosition);
        }
        this.transform.position = targetPosition;
        // update aggro
        if (targetPosition == player.transform.position)
        {
            enemiesScript.UpdateAggro();
            if (enemiesScript.activeEnemyLookup.Count == 0 && targetTileScript.IsEnd)
            {
                missionLogicScript.currentLevel += 1;
                missionLogicScript.NextLevel();
            }
        }
        // pick up ground items
        if (dropsScript.groundItemsLookup.ContainsKey(targetPosition))
        {
            GameObject groundItems = dropsScript.groundItemsLookup[targetPosition];
            while (groundItems.transform.childCount > 0 && inventory.childCount < inventorySize)
            {
                Transform item = groundItems.transform.GetChild(0);
                item.parent = inventory;
                // refresh open inventory UI panel
                Transform characterUI = GameObject.Find("Character UI").transform;
                Transform inventoryUIPanel = characterUI.Find("Inventory UI Panel(Clone)");
                if (inventoryUIPanel != null)
                {
                    InventoryUIScript inventoryUIScript = inventoryUIPanel.GetComponent<InventoryUIScript>();
                    inventoryUIScript.RefreshUI();
                }
            }
            if (groundItems.transform.childCount == 0)
            {
                dropsScript.groundItemsLookup.Remove(targetPosition);
                Destroy(groundItems);
            }
            else
            {
                Debug.Log("inventory full");
            }
        }
    }

    public int IncomingDamage(int damage, GameObject attacker)
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
            return 0;
        }
        // half of incoming damage is reduced by armor
        int halfDamage = damage / 2;
        int armorDamage = (damage - halfDamage - Armor);
        if (armorDamage < 0)
        {
            armorDamage = 0;
        }
        int actualDamage = halfDamage + armorDamage;
        if (actualDamage < 0)
        {
            return 0;
        }
        else
        {
            CurrentHealth -= actualDamage;
            Debug.Log(this.gameObject.name + " took " + actualDamage.ToString() + " damage from " + attacker.name);
            return actualDamage;
        }
    }

    public void Knockback(Vector3 fromPosition, GameObject attacker, int collisionDamage)
    {
        Vector3 difference = this.transform.position - fromPosition;
        Vector3 targetPosition = this.transform.position + difference;
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        if (tileLookup.ContainsKey(targetPosition))
        {
            GameObject tile = tileLookup[targetPosition];
            TileScript tileScript = tile.GetComponent<TileScript>();
            if (tileScript.isOccupied)
            {
                IncomingDamage(collisionDamage, attacker);
            }
            else
            {
                MoveTo(targetPosition);
            }
        }
        else
        {
            IncomingDamage(collisionDamage, attacker);
        }
    }

    public void ReduceCooldowns(int number)
    {
        foreach (GameObject skill in equippedSkills)
        {
            if (skill != null)
            {
                Skill skillScript = skill.GetComponent<Skill>();
                skillScript.ReduceCooldown(number);
            }
        }
    }

    public void ReduceStunDuration(int number)
    {
        stunDuration -= number;
        if (stunDuration < 0)
        {
            stunDuration = 0;
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

    public void DropItems()
    {
        // only drop items if this is an enemy
        if (!enemiesScript.enemyLookup.ContainsKey(this.transform.position))
        {
            return;
        }
        // check if there are ground items already
        GameObject groundItems;
        if (dropsScript.groundItemsLookup.ContainsKey(this.transform.position))
        {
            groundItems = dropsScript.groundItemsLookup[this.transform.position];
        }
        else
        {
            GameObject groundItemsPrefab = Resources.Load<GameObject>("Prefabs/Ground Items");
            groundItems = Instantiate(groundItemsPrefab, drops.transform);
            groundItems.transform.position = this.transform.position;
            dropsScript.groundItemsLookup.Add(this.transform.position, groundItems);
        }
        // drop inventory
        for (int i = 0; i < inventory.childCount; i++)
        {
            Transform inventoryItem = inventory.GetChild(i);
            inventoryItem.parent = groundItems.transform;
        }
        // prepare to drop random item
        List<GameObject> equippedGear = new List<GameObject>();
        if (mainHandWeapon != null)
        {
            equippedGear.Add(mainHandWeapon);
        }
        if (offHandWeapon != null)
        {
            equippedGear.Add(offHandWeapon);
        }
        if (coat != null)
        {
            equippedGear.Add(coat);
        }
        if (gloves != null)
        {
            equippedGear.Add(gloves);
        }
        if (boots != null)
        {
            equippedGear.Add(boots);
        }
        List<GameObject> equippedUtilitySkills = new List<GameObject>();
        for (int i = 0; i < utilitySkills.childCount; i++)
        {
            equippedUtilitySkills.Add(utilitySkills.GetChild(i).gameObject);
        }
        // pick 1 random gear piece or utility skill to drop
        if (equippedGear.Count > 0 || equippedUtilitySkills.Count > 0)
        {
            int totalCount = equippedGear.Count + equippedUtilitySkills.Count;
            int randomIndex = Random.Range(0, totalCount);
            if (randomIndex < equippedGear.Count)
            {
                GameObject gearDrop = equippedGear[randomIndex];
                gearDrop.transform.parent = groundItems.transform;
            }
            else
            {
                int skillIndex = randomIndex - equippedGear.Count;
                GameObject skillDrop = equippedUtilitySkills[skillIndex];
                Skill skillScript = skillDrop.GetComponent<Skill>();
                GameObject skillTomePrefab = Resources.Load<GameObject>("Prefabs/Skill Tome");
                GameObject tomeDrop = Instantiate(skillTomePrefab, groundItems.transform);
                SkillTomeScript tomeScript = tomeDrop.GetComponent<SkillTomeScript>();
                tomeScript.itemSprite = Resources.Load<Sprite>("Items/SkillTome");
                tomeScript.skillName = skillScript.GetSkillName();
            }
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
        finishedBuilding = true;
    }

    void Start()
    {
        Debug.Log("Hello World - I'm " + this.name);
        spriteRenderer = this.gameObject.GetComponent<SpriteRenderer>();
        if (this.gameObject.name == "Player")
        {
            SpriteSheet = Resources.LoadAll<Sprite>("Player");
        }
        maxHealth = 10;
        missionLogic = GameObject.Find("Mission Logic");
        missionLogicScript = missionLogic.GetComponent<MissionLogicScript>();
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        levelBuilderLoaded = true;
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        player = GameObject.Find("Player");
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        drops = GameObject.Find("Drops");
        dropsScript = drops.GetComponent<DropsScript>();
        gear = this.transform.Find("Gear").gameObject;
        gearScript = gear.GetComponent<GearScript>();
        hitSprite = Resources.Load<Sprite>("Hit");
        aggroSprite = Resources.Load<Sprite>("EnemyAggro");
        healthBarStates = Resources.LoadAll<Sprite>("EntityHealthBars");
        _mainHand = gear.transform.Find("Main Hand");
        _offHand = gear.transform.Find("Off Hand");
        _body = gear.transform.Find("Body");
        _hands = gear.transform.Find("Hands");
        _feet = gear.transform.Find("Feet");
        _inventory = this.transform.Find("Inventory");
        _inventorySize = 24;
        _utilitySkills = this.transform.Find("Utility Skills");
        StartCoroutine(WaitForGearBeforePopulating());
    }

    void OnDestroy()
    {
    }
}
